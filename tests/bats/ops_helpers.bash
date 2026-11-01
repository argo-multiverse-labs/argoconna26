# Helpers for the operator-script tests: a local bare "GitHub", an operator clone, a fake
# main checkout, and stubs for git (guard + log), kubectl (a tiny Argo CD), argocd and
# ensure-image. Nothing touches a cluster or the network.
#
# make_ops_fixture sets: ORIGIN (bare repo), OP (operator clone), FIXTURE (the "main
# checkout": .env and .kube live here), STUBS, CALLS (event log), REAL_GIT, OTHER (a second
# clone, for another pusher).
#
# The kubectl stub plays Argo CD for the tracked branch's tip: sync revision is the tip,
# health is Degraded when the tip is armed (200), is not a revert and touched the
# kustomization (an image bump on an armed config), otherwise Healthy. FORCE_HEALTH=<state>
# in the stub dir overrides it.

make_ops_fixture() {
  REAL_GIT="$(command -v git)"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  OP="$BATS_TEST_TMPDIR/operator"
  OTHER="$BATS_TEST_TMPDIR/other"
  FIXTURE="$BATS_TEST_TMPDIR/main"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  : > "$CALLS"
  mkdir -p "$STUBS"

  "$REAL_GIT" init -q --bare -b build/demo "$ORIGIN"
  local seed="$BATS_TEST_TMPDIR/seed"
  "$REAL_GIT" clone -q "$ORIGIN" "$seed" 2>/dev/null
  _ops_git_identity "$seed"
  mkdir -p "$seed/apps/checkout/config" "$seed/apps/checkout/deploy" "$seed/apps/pricing"
  cat > "$seed/apps/checkout/config/checkout-config.yaml" <<'YAML'
# Healthy value is 2000.
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  # Milliseconds to wait for pricing.
  UPSTREAM_TIMEOUT_MS: "2000"
  PRICING_URL: http://pricing.demo.svc:8080
YAML
  cat > "$seed/apps/checkout/deploy/rollout.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
spec:
  replicas: 4
  template:
    metadata:
      annotations:
        example.dev/config-version: "7"
YAML
  cat > "$seed/apps/checkout/kustomization.yaml" <<'YAML'
resources:
  - deploy/rollout.yaml
images:
  - name: checkout
    newTag: v1.4.1
YAML
  printf '# pricing\n' > "$seed/apps/pricing/README.md"
  "$REAL_GIT" -C "$seed" add -A
  "$REAL_GIT" -C "$seed" commit -q -m "seed apps"
  "$REAL_GIT" -C "$seed" push -q origin HEAD:refs/heads/build/demo

  "$REAL_GIT" clone -q --branch build/demo "$ORIGIN" "$OP" 2>/dev/null
  _ops_git_identity "$OP"
  printf '#!/bin/sh\nexit 0\n' > "$OP/.git/hooks/pre-commit"
  chmod +x "$OP/.git/hooks/pre-commit"
  "$REAL_GIT" clone -q --branch build/demo "$ORIGIN" "$OTHER" 2>/dev/null
  _ops_git_identity "$OTHER"

  make_fixture_repo "$FIXTURE"
  mkdir -p "$FIXTURE/.kube"
  printf 'OPERATOR_DIR=%s\n' "$OP" > "$FIXTURE/.env"

  _ops_stubs
  export PATH="$STUBS:$PATH" TOOLS_BIN="$STUBS"
  export ENSURE_IMAGE="$STUBS/ensure-image.sh"
  export ARGO_WAIT_S=6 HEALTH_WAIT_S=6 DEGRADED_WAIT_S=6
  unset STAGE NAIVE_STOP_AT_GREEN PRECOMMIT_HOOK_SRC OPERATOR_REMOTE GH_TOKEN
}

_ops_git_identity() {
  "$REAL_GIT" -C "$1" config user.email "test@example.invalid"
  "$REAL_GIT" -C "$1" config user.name "test"
  "$REAL_GIT" -C "$1" config commit.gpgsign false
}

_ops_stubs() {
  # git: refuse force and --no-verify, log pushes, optionally let another clone push first.
  cat > "$STUBS/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    --force*|-f|--no-verify|+refs/*|+HEAD*)
      echo "FORBIDDEN git \$*" >> "$CALLS"; echo "forbidden: \$a" >&2; exit 99 ;;
  esac
done
sub=""
for a in "\$@"; do case "\$a" in -C) ;; -*) ;; /*) ;; *) sub="\$a"; break ;; esac; done
if [ "\$sub" = push ]; then
  echo PUSH >> "$CALLS"
  if [ -n "\${INTERFERE_ONCE:-}" ] && [ ! -e "$BATS_TEST_TMPDIR/interfered" ]; then
    : > "$BATS_TEST_TMPDIR/interfered"
    echo "other work" > "$OTHER/other.txt"
    "$REAL_GIT" -C "$OTHER" add other.txt
    "$REAL_GIT" -C "$OTHER" commit -q -m "other pusher"
    "$REAL_GIT" -C "$OTHER" push -q origin HEAD:refs/heads/build/demo
    echo INTERFERED >> "$CALLS"
  fi
fi
exec "$REAL_GIT" "\$@"
STUB
  # kubectl: a tiny Argo CD.
  cat > "$STUBS/kubectl" <<STUB
#!/usr/bin/env bash
tip() { "$REAL_GIT" --git-dir="$ORIGIN" rev-parse refs/heads/build/demo; }
case "\$*" in
  *"config current-context"*) echo kind-argoconna26 ;;
  *"annotate application"*)
    app=\$(grep -o 'application [a-z]*' <<<"\$*" | cut -d' ' -f2)
    echo "ANNOTATE \$app" >> "$CALLS" ;;
  *"get application"*"sync.revision"*)
    app=\$(grep -o 'application [a-z]*' <<<"\$*" | cut -d' ' -f2)
    echo "REV \$app" >> "$CALLS"
    echo "\$(tip) Synced Succeeded" ;;
  *"get application"*"health.status"*)
    app=\$(grep -o 'application [a-z]*' <<<"\$*" | cut -d' ' -f2)
    echo "HEALTH \$app" >> "$CALLS"
    if [ -s "$STUBS/FORCE_HEALTH" ]; then cat "$STUBS/FORCE_HEALTH"; exit 0; fi
    cfg=\$("$REAL_GIT" --git-dir="$ORIGIN" show "\$(tip):apps/checkout/config/checkout-config.yaml" | grep UPSTREAM_TIMEOUT_MS)
    subj=\$("$REAL_GIT" --git-dir="$ORIGIN" log -1 --format=%s "\$(tip)")
    files=\$("$REAL_GIT" --git-dir="$ORIGIN" diff-tree --no-commit-id --name-only -r "\$(tip)")
    if grep -q '"200"' <<<"\$cfg" && [[ "\$subj" != Revert* ]] && grep -q kustomization.yaml <<<"\$files"; then
      echo Degraded
    else echo Healthy; fi ;;
  *) echo "kubectl stub: unexpected \$*" >&2; exit 1 ;;
esac
STUB
  # argocd: must never be called.
  cat > "$STUBS/argocd" <<STUB
#!/usr/bin/env bash
echo "ARGOCD CLI CALLED \$*" >> "$CALLS"
echo "argocd must not be used" >&2
exit 97
STUB
  cat > "$STUBS/ensure-image.sh" <<STUB
#!/usr/bin/env bash
echo "ENSURE \$*" >> "$CALLS"
echo "present checkout:\$2"
STUB
  chmod +x "$STUBS"/*
}

# ops RUN_ARGS... : run a script from the fake main checkout (cwd decides main_root).
ops_run() {
  ( cd "$FIXTURE" && "$@" )
}

# Source git-ops.sh and run a snippet in the fake main checkout.
in_ops() {
  ( cd "$FIXTURE" && bash -c ". '$REPO_ROOT/scripts/git-ops.sh'; load_env; $1" )
}

op_head()   { "$REAL_GIT" -C "$OP" rev-parse HEAD; }
origin_tip() { "$REAL_GIT" --git-dir="$ORIGIN" rev-parse refs/heads/build/demo; }
origin_file() { "$REAL_GIT" --git-dir="$ORIGIN" show "refs/heads/build/demo:$1"; }
origin_log() { "$REAL_GIT" --git-dir="$ORIGIN" log --format=%s refs/heads/build/demo; }
