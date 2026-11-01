# One install path. Pins live in versions.env, names in demo.env, secrets in .env (never read by make).
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

# The main checkout, even from a worktree (P12).
ROOT      := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
MAIN_ROOT := $(patsubst %/,%,$(dir $(shell git -C $(ROOT) rev-parse --path-format=absolute --git-common-dir)))

include $(ROOT)/versions.env
include $(ROOT)/demo.env

# P25: the pinned tools win on PATH. TOOLS_BIN: command line > .env > demo.env.
ENV_TOOLS_BIN := $(shell sed -n 's/^TOOLS_BIN=//p' $(MAIN_ROOT)/.env 2>/dev/null | tail -1)
ifneq ($(ENV_TOOLS_BIN),)
  ifeq ($(origin TOOLS_BIN),file)
    TOOLS_BIN := $(ENV_TOOLS_BIN)
  endif
endif
export PATH := $(TOOLS_BIN):$(PATH)

# Isolated kubeconfig (P3). Luke's default kubeconfig is never used.
export KUBECONFIG := $(MAIN_ROOT)/$(KUBECONFIG_REL)
export HELM_CONFIG_HOME := $(MAIN_ROOT)/.kube/helm/config
export HELM_CACHE_HOME  := $(MAIN_ROOT)/.kube/helm/cache
export HELM_DATA_HOME   := $(MAIN_ROOT)/.kube/helm/data
.EXPORT_ALL_VARIABLES:

# Each recipe is one shell (.ONESHELL). A guard is the first line:
#   LOCKED  takes the cluster lock and refuses any context but kind-argoconna26
#   CTX     checks the context only (read-only targets)
#   PRE     takes the lock but does not need the cluster (kind create / delete)
LOCKED = . $(ROOT)/scripts/common.sh; load_env; cluster_lock; require_context
CTX    = . $(ROOT)/scripts/common.sh; load_env; require_context
PRE    = . $(ROOT)/scripts/common.sh; load_env; cluster_lock

.PHONY: help
help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

################################################################################
# Tools and checks                                                             #
################################################################################

.PHONY: vendor
vendor: ## Check required tools are present and at the pinned versions
	@$(ROOT)/scripts/vendor-check.sh

.PHONY: lint
lint: ## shellcheck the scripts
	@cd $(ROOT)
	shopt -s nullglob
	files=(scripts/*.sh tests/e2e/*.sh)
	shellcheck -x "$${files[@]}"
	echo "lint: OK"

.PHONY: test-bats
test-bats: ## Run the bats suite
	@cd $(ROOT) && bats tests/bats

.PHONY: consistency
consistency: ## Hardcoded versions or names that differ from versions.env / demo.env
	@$(ROOT)/scripts/check-consistency.sh $(ROOT)

################################################################################
# Cluster lifecycle                                                            #
################################################################################

KIND_CONFIG_VARS := $${CLUSTER_NAME} $${KIND_NODE_IMAGE} $${HOST_BIND} $${PORT_ARGOCD} $${PORT_GRAFANA} $${PORT_PROMETHEUS} $${PORT_BRIDGE} $${PORT_SIM} $${PORT_LITELLM}

.PHONY: kind-cluster
kind-cluster: ## Create the kind cluster (skips when it exists)
	@$(PRE)
	mkdir -p "$$(dirname "$$KUBECONFIG")"
	if kind get clusters 2>/dev/null | grep -qx "$$CLUSTER_NAME"; then
	  log_info "skip: cluster $$CLUSTER_NAME exists"
	  [[ -s "$$KUBECONFIG" ]] || kind export kubeconfig --name "$$CLUSTER_NAME" --kubeconfig "$$KUBECONFIG"
	else
	  envsubst '$(KIND_CONFIG_VARS)' < $(ROOT)/cluster/kind-config.yaml \
	    | kind create cluster --config - --kubeconfig "$$KUBECONFIG" --wait 120s
	fi
	chmod 600 "$$KUBECONFIG"
	require_context
	k wait --for=condition=Ready nodes --all --timeout=120s

.PHONY: rm-kind
rm-kind: ## Delete the kind cluster and its isolated kubeconfig
	@$(PRE)
	[[ "$$CLUSTER_NAME" == "argoconna26" ]] || die "refusing to delete cluster '$$CLUSTER_NAME'"
	# the Postgres PVC dies with the cluster, so keep LiteLLM's spend first (Task 3.11 Step 5)
	if k get --raw=/readyz >/dev/null 2>&1; then
	  $(ROOT)/scripts/litellm.sh spend-export || log_warn "llm-spend-export failed; LiteLLM spend of this cluster is not kept"
	fi
	kind delete cluster --name "$$CLUSTER_NAME" --kubeconfig "$$KUBECONFIG"
	rm -f "$$KUBECONFIG"

################################################################################
# Platform                                                                     #
################################################################################

.PHONY: helm-repos
helm-repos: ## Add the Helm repos to the isolated Helm config
	@$(CTX)
	helm repo add argo "$$ARGO_HELM_REPO" --force-update >/dev/null
	helm repo add prometheus-community "$$PROM_HELM_REPO" --force-update >/dev/null
	helm repo update >/dev/null

.PHONY: argocd-install
argocd-install: helm-repos ## Install Argo CD (skips when unchanged)
	@$(LOCKED)
	helm_ensure "$$ARGOCD_RELEASE" argo/argo-cd "$$ARGOCD_CHART_VERSION" "$$NS_ARGOCD" \
	  $(ROOT)/platform/argocd/values.yaml $(ROOT)/platform/argocd/notifications-cdevents.yaml
	k rollout status statefulset/argocd-application-controller -n "$$NS_ARGOCD" --timeout=300s

.PHONY: argocd-password
argocd-password: ## Print the Argo CD admin password
	@$(CTX) 2>/dev/null
	k -n "$$NS_ARGOCD" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: rollouts-install
rollouts-install: helm-repos ## Install Argo Rollouts (skips when unchanged)
	@$(LOCKED)
	helm_ensure "$$ROLLOUTS_RELEASE" argo/argo-rollouts "$$ROLLOUTS_CHART_VERSION" "$$NS_ROLLOUTS" $(ROOT)/platform/rollouts/values.yaml

.PHONY: secrets-base secrets-late secrets
secrets-base: ## Load .env into Secrets that need no running service
	@$(ROOT)/scripts/secrets.sh base
secrets-late: ## Load Secrets that need running services (slice 3)
	@$(ROOT)/scripts/secrets.sh late
secrets: secrets-base secrets-late ## Load all Secrets

.PHONY: grafana-token
grafana-token: ## Service account + token for cdevents-sim's Grafana annotations (needs Grafana up)
	@$(ROOT)/scripts/grafana-token.sh

.PHONY: kps-install
kps-install: helm-repos ## Install kube-prometheus-stack (needs the grafana-admin Secret)
	@$(LOCKED)
	k get secret grafana-admin -n "$$NS_MONITORING" >/dev/null 2>&1 || die "grafana-admin Secret missing: run 'make secrets-base' first"
	helm_ensure "$$KPS_RELEASE" prometheus-community/kube-prometheus-stack "$$KPS_CHART_VERSION" "$$NS_MONITORING" $(ROOT)/platform/kps/values.yaml
	# helm --wait covers only chart-owned workloads. The Prometheus StatefulSet comes from the
	# operator afterwards, so wait for it too (verify-idempotent snapshots right after this).
	sts="prometheus-$${KPS_RELEASE}-prometheus"
	wait_for "statefulset $$sts to exist" 300 k get statefulset "$$sts" -n "$$NS_MONITORING"
	k rollout status statefulset/"$$sts" -n "$$NS_MONITORING" --timeout=300s

.PHONY: litellm-install
litellm-install: ## Install LiteLLM and its Postgres (needs the litellm Secrets from secrets-base)
	@$(LOCKED)
	for s in litellm-masterkey litellm-db litellm-env; do
	  k get secret "$$s" -n "$$NS_AIOPS" >/dev/null 2>&1 || die "Secret $$s missing: run 'make secrets-base' first"
	done
	[[ -n "$${LLM_BUDGET_USD:-}" ]] || die "LLM_BUDGET_USD is missing in .env"
	k apply -f $(ROOT)/platform/litellm/postgres.yaml
	k rollout status statefulset/litellm-postgres -n "$$NS_AIOPS" --timeout=180s
	cfg="$$(mktemp)"
	envsubst '$${LLM_BUDGET_USD}' < $(ROOT)/platform/litellm/config.yaml > "$$cfg"
	rc=0
	helm_ensure litellm oci://ghcr.io/berriai/litellm-helm "$$LITELLM_CHART_VERSION" "$$NS_AIOPS" \
	  $(ROOT)/platform/litellm/values.yaml "$$cfg" || rc=$$?
	rm -f "$$cfg"
	(( rc == 0 )) || exit "$$rc"
	k rollout status deployment/litellm -n "$$NS_AIOPS" --timeout=300s

.PHONY: litellm-keys
litellm-keys: ## Virtual keys holmes and judge -> Secrets holmes-llm and judge-llm
	@$(ROOT)/scripts/litellm.sh keys

.PHONY: llm-spend-export
llm-spend-export: ## Write LiteLLM spend to .dryruns/llm-spend/ (rm-kind runs it; by hand it double counts until rebuilt)
	@$(ROOT)/scripts/litellm.sh spend-export

.PHONY: llm-spend
llm-spend: ## Live and cumulative LLM spend against the budget
	@$(ROOT)/scripts/litellm.sh spend

################################################################################
# Images                                                                       #
################################################################################

# build_image NAME DIR: docker build NAME:latest-build with the pinned base images.
IMG_BUILD = build_image() { \
	  docker build -q -t "$$1:latest-build" --build-arg PYTHON_IMAGE="$$PYTHON_IMAGE" --build-arg UV_IMAGE="$$UV_IMAGE" "$$2" >/dev/null; \
	  log_info "built $$1:latest-build"; }

.PHONY: images
images: ## Build the demo images and load them into the kind nodes (skips what is present)
	@$(LOCKED)
	$(IMG_BUILD)
	cd $(ROOT)
	build_image checkout apps/checkout
	build_image pricing apps/pricing
	build_image loadgen apps/loadgen
	# bridge and cdevents-sim join once their directories hold a Dockerfile
	have_bridge=0; have_sim=0
	[[ -f bridge/Dockerfile ]] && { build_image bridge bridge; have_bridge=1; }
	[[ -f cdevents-sim/Dockerfile ]] && { build_image cdevents-sim cdevents-sim; have_sim=1; }
	IFS=, read -ra tags <<<"$$CHECKOUT_PRELOAD_TAGS"
	for t in "$${tags[@]}"; do $(ROOT)/scripts/ensure-image.sh checkout "$$t"; done
	$(ROOT)/scripts/ensure-image.sh pricing "$$PRICING_TAG"
	$(ROOT)/scripts/ensure-image.sh loadgen "$$LOADGEN_TAG"
	(( have_bridge )) && $(ROOT)/scripts/ensure-image.sh bridge "$$BRIDGE_TAG"
	(( have_sim )) && $(ROOT)/scripts/ensure-image.sh cdevents-sim "$$SIM_TAG"
	true

.PHONY: image-load
image-load: images ## Alias of images

.PHONY: redeploy-bridge redeploy-sim
redeploy-bridge: images ## Rebuild the bridge image and restart its pods when they run a stale one
	@$(LOCKED)
	$(ROOT)/scripts/ensure-image.sh --redeploy bridge
redeploy-sim: images ## Rebuild the cdevents-sim image and restart its pods when they run a stale one
	@$(LOCKED)
	$(ROOT)/scripts/ensure-image.sh --redeploy cdevents-sim

################################################################################
# Policy                                                                       #
################################################################################

.PHONY: policy-verify
policy-verify: ## Run the Rego unit tests
	@cd $(ROOT) && conftest verify --policy policy

.PHONY: policy-check
policy-check: ## Golden-path labels on every app's rendered manifests (conftest, no cluster needed)
	@cd $(ROOT)
	rc=0
	for d in apps/*/; do
	  [[ -f "$$d/kustomization.yaml" ]] || continue
	  echo "policy-check: $$d"
	  kubectl kustomize "$$d" | conftest test --policy policy --namespace goldenpath --parser yaml - || rc=1
	done
	exit $$rc

################################################################################
# GitOps                                                                       #
################################################################################

.PHONY: gitops-bootstrap
gitops-bootstrap: ## Apply the root app-of-apps (Argo CD then creates checkout, pricing, loadgen)
	@$(LOCKED)
	# the images must be on the nodes first: imagePullPolicy is Never
	k create namespace "$$NS_DEMO" --dry-run=client -o yaml | k apply -f -
	k apply -f $(ROOT)/gitops/root.yaml

################################################################################
# Build, rebuild, info, verification                                           #
################################################################################

# Later slices insert targets at fixed positions; the final order is written once in Task 3.16.
# disarm-git-only comes before gitops-bootstrap, so an armed branch never meets a fresh
# cluster (Review Focus 1): Argo's first sync already reads the disarmed config.
BUILD_STEPS := vendor kind-cluster argocd-install rollouts-install secrets-base kps-install images disarm-git-only gitops-bootstrap
SNAP_DIR    := $(MAIN_ROOT)/.kube/idempotency

.PHONY: build-all
build-all: ## Create the whole stack (safe to run twice)
	@$(PRE)
	$(MAKE) --no-print-directory $(BUILD_STEPS)
	log_info "build-all: done"

.PHONY: rebuild
rebuild: ## Delete the cluster and build it again
	@$(PRE)
	$(MAKE) --no-print-directory rm-kind build-all

.PHONY: preflight
preflight: ## Pre-flight checks (exit 1 on any FAIL)
	@$(ROOT)/scripts/preflight.sh $(RUNG)

.PHONY: info
info: ## Print URLs and how to get credentials (never the passwords)
	@. $(ROOT)/scripts/common.sh; load_env
	cat <<INFO
	Argo CD     $$ARGOCD_HOST_URL      user admin, password: make -s argocd-password
	Grafana     $$GRAFANA_HOST_URL     user admin, password: GRAFANA_ADMIN_PASSWORD in .env
	Prometheus  $$PROM_HOST_URL
	Context     $$CLUSTER_CONTEXT (isolated kubeconfig: $$KUBECONFIG)
	INFO

################################################################################
# Operator scripts (Git pushes that drive the incident; see scripts/git-ops.sh) #
################################################################################

.PHONY: operator-clone
operator-clone: ## Clone the repo for the operator scripts and install the pre-commit hook
	@$(ROOT)/scripts/git-ops.sh operator-clone

.PHONY: seed-history
seed-history: ## Disarm, then commit PR-242 and one harmless docs change
	@$(ROOT)/scripts/seed-history.sh

.PHONY: bump
bump: ## Bump the checkout image tag by one patch version
	@$(ROOT)/scripts/git-ops.sh bump

.PHONY: rearm
rearm: ## Re-apply the PR-242 timeout, then bump the image (refuses when armed)
	@$(ROOT)/scripts/rearm.sh

.PHONY: fix
fix: ## Restore the timeout and bump config-version in one commit
	@$(ROOT)/scripts/fix.sh

.PHONY: naive-revert
naive-revert: ## Revert the last image bump: green but wrong
	@$(ROOT)/scripts/naive-revert.sh

.PHONY: disarm
disarm: ## Timeout back to 2000 (IMAGE=vX.Y.Z also pins the tag; GIT_ONLY=1 skips the wait)
	@$(ROOT)/scripts/git-ops.sh disarm $(if $(IMAGE),--image $(IMAGE)) $(if $(GIT_ONLY),--git-only)

.PHONY: disarm-git-only
disarm-git-only: ## (build-all) Push the disarm before Argo's first sync; skips without an operator clone
	@$(ROOT)/scripts/git-ops.sh disarm --git-only

.PHONY: snapshot
snapshot: ## (internal) record object UIDs and restart counts
	@mkdir -p $(SNAP_DIR)
	$(ROOT)/scripts/idempotency.sh snapshot $(SNAP_DIR)/before.txt

.PHONY: compare
compare: ## (internal) compare against the last snapshot
	@$(ROOT)/scripts/idempotency.sh snapshot $(SNAP_DIR)/after.txt
	$(ROOT)/scripts/idempotency.sh compare $(SNAP_DIR)/before.txt $(SNAP_DIR)/after.txt

.PHONY: verify-idempotent
verify-idempotent: ## rm-kind, build-all, build-all, compare, preflight
	@$(PRE)
	mkdir -p $(SNAP_DIR)
	$(MAKE) --no-print-directory rm-kind build-all
	$(MAKE) --no-print-directory snapshot
	$(MAKE) --no-print-directory build-all 2>&1 | tee $(SNAP_DIR)/second-build.log
	grep -q "skip: cluster $$CLUSTER_NAME exists" $(SNAP_DIR)/second-build.log \
	  || die "the second build-all did not log 'skip: cluster $$CLUSTER_NAME exists'"
	$(MAKE) --no-print-directory compare
	$(MAKE) --no-print-directory preflight
	log_info "verify-idempotent: OK"
