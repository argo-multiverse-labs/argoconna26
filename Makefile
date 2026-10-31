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
	helm_ensure "$$ARGOCD_RELEASE" argo/argo-cd "$$ARGOCD_CHART_VERSION" "$$NS_ARGOCD" $(ROOT)/platform/argocd/values.yaml
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

################################################################################
# Build, rebuild, info, verification                                           #
################################################################################

# Later slices insert targets at fixed positions; the final order is written once in Task 3.16.
BUILD_STEPS := vendor kind-cluster argocd-install rollouts-install secrets-base kps-install
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
