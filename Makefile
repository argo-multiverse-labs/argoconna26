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
