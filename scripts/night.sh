#!/usr/bin/env bash
# The rung-3 scheduled job (Task 5.5): one user-level unit, started now (make night) or by an
# optional timer (make timer-arm AT=...).
#
#   scripts/night.sh job-install          render and install argoconna26-rearm.service (idempotent)
#   scripts/night.sh night                start that unit now; exit with its ExecMainStatus.
#                                         .operator/last-run gets RUN_TS (the unit's start, the
#                                         verifier's window start), RUN_MONO and T_TYPED (when
#                                         the command was typed, before its own preflight)
#   scripts/night.sh timer-arm "YYYY-MM-DD HH:MM"   install and start argoconna26-rearm.timer
#   scripts/night.sh timer-disarm         stop and remove the timer and job.env
#   scripts/night.sh timer-status         the next trigger
#
# `night` and `timer-arm` refuse (before starting anything) when:
#   exit 5  cluster_lock is held, by anyone (the unit cannot inherit the lock; rearm takes its own)
#   exit 6  autonomy on the tracked branch (read from GitHub) is not "act"
#   exit 9  scripts/preflight.sh 3 --armed fails
#   exit 2  usage, a past or malformed AT, or an unusable runtime dir
# `night` otherwise exits with the unit's ExecMainStatus: the quiet preflight's 1, rearm's own
# code (7: already armed), and so on. Through `make night` / `make timer-arm` every failure
# shows as make's 2 (make maps any recipe failure to 2); call scripts/night.sh for the real code.
# They then write $XDG_RUNTIME_DIR/argoconna26/job.env (0600, outside the repo) with GH_TOKEN
# from `gh auth token` (P13). The unit's ExecStopPost removes it.
# Never starts anything except units named argoconna26-* (systemctl --user).
#
# Test overrides: SYSTEMD_USER_DIR (where units are installed), XDG_RUNTIME_DIR, NIGHT_PREFLIGHT.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NIGHT_DIR="$COMMON_SH_DIR"
UNIT_NAME=argoconna26-rearm
EXIT_AUTONOMY=6
EXIT_PREFLIGHT=9

_unit_dir() { printf '%s' "${SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"; }
_sctl() { systemctl --user "$@"; }

# The runtime dir must exist and sit outside the repo, or the token would be one `git add` away.
_job_env_dir() {
  local rt="${XDG_RUNTIME_DIR:-}" root
  [[ -n "$rt" && -d "$rt" ]] || { log_error "XDG_RUNTIME_DIR is not set or not a directory"; return 2; }
  root="$(main_root)"
  case "$rt/" in "$root"/*) log_error "refusing: XDG_RUNTIME_DIR is inside the repo"; return 2 ;; esac
  printf '%s/argoconna26' "$rt"
}

# Values rendered into unit files: no characters systemd or the substitution would reinterpret.
_safe_value() { [[ "$1" =~ ^[A-Za-z0-9_./:+@=,-]+$ ]] || die "refusing to render '$1' into a unit file"; }

_render() { # TEMPLATE KEY=VALUE... : print the template with @KEY@ replaced
  local out kv
  out="$(<"$1")"
  shift
  for kv in "$@"; do
    _safe_value "${kv#*=}"
    out="${out//@${kv%%=*}@/${kv#*=}}"
  done
  printf '%s\n' "$out"
}

# The PATH the unit gets (P25): TOOLS_BIN first, then where the other tools were found, then the
# base directories. The systemd user manager's own PATH lacks linuxbrew and puts /usr/local/bin first.
_unit_path() {
  local -a dirs=("$TOOLS_BIN")
  local tool bin dir d seen
  for tool in yq uv docker gh jq kind kubectl; do
    bin="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$bin" ]] && dirs+=("$(dirname "$bin")")
  done
  dirs+=(/usr/local/bin /usr/bin /bin)
  local out=""
  for dir in "${dirs[@]}"; do
    seen=0
    for d in ${out//:/ }; do [[ "$d" == "$dir" ]] && seen=1; done
    ((seen)) || out+="${out:+:}$dir"
  done
  printf '%s' "$out"
}

cmd_job_install() {
  local root dir
  root="$(main_root)"
  dir="$(_unit_dir)"
  mkdir -p "$dir"
  _render "$NIGHT_DIR/systemd/$UNIT_NAME.service.in" \
    REPO="$root" KUBECONFIG="$root/$KUBECONFIG_REL" PATH="$(_unit_path)" \
    EVIDENCE_DIR="$(evidence_dir)" >"$dir/$UNIT_NAME.service"
  _sctl daemon-reload
  log_info "installed $dir/$UNIT_NAME.service"
}

# ------------------------------------------------------------------ refusals
# True when some process holds the cluster lock, including an ancestor of this one: the unit
# cannot inherit it, so CLUSTER_LOCK_HELD is deliberately ignored.
_refuse_if_locked() {
  local lockfile holder
  lockfile="$(_lock_file)"
  [[ -e "$lockfile" ]] || return 0
  if _lock_is_held "$lockfile"; then
    holder="$(head -n1 "$lockfile" 2>/dev/null || true)"
    refuse 5 "lock is held" "cluster lock is held by: ${holder:-unknown holder}; nothing started"
  fi
}

_refuse_unless_armed() {
  local lvl
  lvl="$(tracked_autonomy_level || true)"
  [[ "$lvl" == act ]] \
    || refuse "$EXIT_AUTONOMY" "autonomy not act" "autonomy on $TRACKED_BRANCH is '${lvl:-unreadable}', not act; promote first"
  quiet "${NIGHT_PREFLIGHT:-$NIGHT_DIR/preflight.sh}" 3 --armed \
    || refuse "$EXIT_PREFLIGHT" "preflight failed" "preflight 3 --armed failed (see above); nothing started"
}

_write_job_env() {
  local dir token
  dir="$(_job_env_dir)" || exit 2
  token="$(gh auth token 2>/dev/null)" && [[ -n "$token" ]] \
    || refuse 1 "no gh token" "gh auth token returned nothing; run gh auth login"
  (umask 077; mkdir -p "$dir"; printf 'GH_TOKEN=%s\n' "$token" >"$dir/job.env")
  chmod 600 "$dir/job.env"
}

_monotonic_us() {
  python3 -c 'import time; print(time.monotonic_ns() // 1000)' 2>/dev/null \
    || awk '{printf "%d\n", $1 * 1000000}' /proc/uptime
}

_require_unit() {
  _sctl cat "$UNIT_NAME.service" >/dev/null 2>&1 \
    || refuse 1 "unit missing" "$UNIT_NAME.service is not installed; run make job-install"
}

# -------------------------------------------------------------------- night
cmd_night() {
  local rc=0 status run_ts run_mono root t_typed
  t_typed="$(date +%s)"  # when the operator typed it, before this script's own preflight
  _refuse_if_locked
  _require_unit
  _refuse_unless_armed
  _write_job_env
  root="$(main_root)"
  run_ts="$(date +%s)"
  run_mono="$(_monotonic_us)"
  mkdir -p "$root/.operator"
  printf 'RUN_TS=%s\nRUN_MONO=%s\nT_TYPED=%s\n' "$run_ts" "$run_mono" "$t_typed" >"$root/.operator/last-run"
  beat "running the nightly job now"
  _sctl start "$UNIT_NAME.service" >/dev/null 2>&1 || rc=$?
  status="$(_sctl show "$UNIT_NAME.service" -p ExecMainStatus --value 2>/dev/null || true)"
  if [[ "$status" =~ ^[0-9]+$ && "$status" -ne 0 ]]; then
    log_info "job exited with status $status (journalctl --user -u $UNIT_NAME --since @$run_ts)"
    exit "$status"
  fi
  if ((rc != 0)); then
    log_info "starting the job failed (systemctl status $rc)"
    exit "$rc"
  fi
}

# -------------------------------------------------------------------- timer
cmd_timer_arm() {
  local at="${1:-}" epoch dir tpl
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]] \
    || { log_error 'usage: timer-arm "YYYY-MM-DD HH:MM"'; exit 2; }
  epoch="$(date -d "$at" +%s 2>/dev/null)" || { log_error "AT '$at' is not a valid time"; exit 2; }
  (( epoch > $(date +%s) )) || { log_error "AT '$at' is not in the future"; exit 2; }
  _refuse_if_locked
  _require_unit
  _refuse_unless_armed
  _write_job_env
  dir="$(_unit_dir)"
  # AT passed the strict date pattern above, so it is safe to put in the unit as is.
  tpl="$(<"$NIGHT_DIR/systemd/$UNIT_NAME.timer.in")"
  printf '%s\n' "${tpl//@AT@/$at}" >"$dir/$UNIT_NAME.timer"
  _sctl daemon-reload
  _sctl start "$UNIT_NAME.timer"
  log_info "timer armed for $at (laptop awake and session logged in)"
}

cmd_timer_disarm() {
  local dir envdir
  dir="$(_unit_dir)"
  _sctl stop "$UNIT_NAME.timer" >/dev/null 2>&1 || true
  rm -f "$dir/$UNIT_NAME.timer"
  _sctl daemon-reload
  envdir="$(_job_env_dir 2>/dev/null)" && rm -f "$envdir/job.env"
  log_info "timer removed"
}

cmd_timer_status() {
  _sctl list-timers "$UNIT_NAME.timer" --all --no-pager
}

main() {
  local sub="${1:-}"
  load_env
  case "$sub" in
    job-install) cmd_job_install ;;
    night) cmd_night ;;
    timer-arm) shift; cmd_timer_arm "$@" ;;
    timer-disarm) cmd_timer_disarm ;;
    timer-status) cmd_timer_status ;;
    *) log_error "usage: night.sh job-install|night|timer-arm AT|timer-disarm|timer-status"; exit 2 ;;
  esac
}

main "$@"
