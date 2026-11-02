#!/usr/bin/env bash
# Shared plumbing for the e2e scripts (tests/e2e/rung*.sh, failure-paths.sh, slice2.sh).
#
# Source it after scripts/common.sh (or git-ops.sh), with E2E_NAME set to the script's short
# name (the prefix on its failure lines). run_make and run_promo read ROOT and RUN_LOG, which
# the caller's main sets before the first call. Unlike assert.sh, the helpers here write: to the
# run log, and label_pr to GitHub.
# shellcheck shell=bash

now() { date +%s; }
step() { printf '\n== %s\n' "$*" >&2; }
fail() { log_error "${E2E_NAME:?}: $*"; exit 1; }

# run_logged WHAT CMD... : run CMD with its output to stderr and the run log; stdout returned.
# A non-zero exit fails the run as "WHAT exited N".
run_logged() {
  local what="$1" out rc=0
  shift
  out="$("$@" 2> >(tee -a "$RUN_LOG" >&2))" || rc=$?
  printf '%s\n' "$out" | tee -a "$RUN_LOG" >&2
  ((rc == 0)) || fail "$what exited $rc"
  printf '%s\n' "$out"
}

run_make() { run_logged "make $*" make --no-print-directory -C "$ROOT" "$@"; } # TARGET...
run_promo() { run_logged "promotion-pr.sh $*" "$ROOT/scripts/promotion-pr.sh" "$@"; } # SUBCOMMAND ARGS...

# label_pr PR LABEL : through REST, not `gh pr edit --add-label` (that fails on the
# classic-projects GraphQL field).
label_pr() { gh api -X POST "repos/$REPO_SLUG/issues/$1/labels" -f "labels[]=$2" >/dev/null; }
label_demo_reset() { label_pr "$1" demo-reset; } # PR
