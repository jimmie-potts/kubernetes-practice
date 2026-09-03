#!/usr/bin/env bash
# Shared helpers for scripts/drills/phase-N.sh. Sourced by each drill, never run.
#
# Environment:
#   FORGE_CONTEXT      kubectl context to break (default kind-dc-east)
#   FORGE_HTTP_PORT    host port of that data center's ingress (default 8080)
#   FORGE_DRILL_FAULT  force a named fault instead of a random pick (used by validation)
#
# Each drill defines PHASE, FAULTS, do_break, do_check, do_undo, then calls main.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX="${FORGE_CONTEXT:-kind-dc-east}"
CLUSTER="${CTX#kind-}"
HTTP_PORT="${FORGE_HTTP_PORT:-8080}"
ACME="$REPO/deploy/tenants/acme"
STATE_DIR="$REPO/.scratch/drills"
STATE_FILE="$STATE_DIR/$PHASE.fault"

k() { kubectl --context "$CTX" "$@"; }
say() { printf '%s\n' "$*"; }
die() { printf 'drill: %s\n' "$*" >&2; exit 1; }

active_fault() { cat "$STATE_FILE" 2>/dev/null || true; }
set_fault() { mkdir -p "$STATE_DIR"; printf '%s\n' "$1" > "$STATE_FILE"; }
clear_fault() { rm -f "$STATE_FILE"; }

pick_fault() {
  if [[ -n "${FORGE_DRILL_FAULT:-}" ]]; then
    local f
    for f in "$@"; do [[ "$f" == "$FORGE_DRILL_FAULT" ]] && { printf '%s\n' "$f"; return; }; done
    die "unknown fault '$FORGE_DRILL_FAULT'; choose one of: $*"
  fi
  local i=$(( RANDOM % $# + 1 ))
  printf '%s\n' "${!i}"
}

# wait_for <seconds> <command...>: retry the command every 2s until it succeeds.
wait_for() {
  local secs=$1; shift
  local end=$(( SECONDS + secs ))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= end )) && return 1
    sleep 2
  done
}

http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null || true; }

pass() { say "PASS: $*"; clear_fault; }
fail() { say "FAIL: $*"; exit 1; }

main() {
  case "${1:-}" in
    break)
      [[ -z "$(active_fault)" ]] || die "a drill is already active. Test your fix with '$0 check', or repair with '$0 undo'."
      preflight; do_break ;;
    check) [[ -n "$(active_fault)" ]] || die "no drill is active; start one with: $0 break"; do_check ;;
    undo) [[ -n "$(active_fault)" ]] || die "no drill is active; start one with: $0 break"; do_undo ;;
    *) say "usage: $0 break|check|undo"; say "  break  inject one random fault into $CLUSTER"; say "  check  test whether your fix worked"; say "  undo   give up: name the fault and repair it"; exit 2 ;;
  esac
}
