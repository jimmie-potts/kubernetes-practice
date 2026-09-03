#!/usr/bin/env bash
# Phase 0 drill: one of two faults hits the data center. Diagnose it with
# kubectl and docker, fix it, then run:  scripts/drills/phase-0.sh check
PHASE=phase-0
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAULTS=(node-paused stale-kubeconfig)
WORKER="${CLUSTER}-worker2"

preflight() {
  docker inspect "$WORKER" >/dev/null 2>&1 || die "no container named $WORKER; is the $CLUSTER cluster up?"
  k get nodes >/dev/null 2>&1 || die "kubectl cannot reach $CTX; finish the lab's checkpoint first"
}

do_break() {
  local fault; fault=$(pick_fault "${FAULTS[@]}")
  case "$fault" in
    node-paused) docker pause "$WORKER" >/dev/null ;;
    stale-kubeconfig) kubectl config set-cluster "$CTX" --server=https://127.0.0.1:1 >/dev/null ;;
  esac
  set_fault "$fault"
  say "Fault injected into $CLUSTER. Give it a minute, then run the checkpoint commands and describe what you see."
  say "Test your fix with: $0 check    Give up and repair with: $0 undo"
}

node_ready() { [[ "$(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; }

do_check() {
  case "$(active_fault)" in
    node-paused)
      [[ "$(docker inspect -f '{{.State.Paused}}' "$WORKER")" == "false" ]] || fail "one machine is still not answering; keep looking"
      wait_for 90 node_ready "$WORKER" || fail "the machine is back, but its node has not reported Ready yet; wait a little and check again"
      pass "you fixed it. The host $WORKER was paused, the bare-metal version of a machine going dark, and its node is Ready again." ;;
    stale-kubeconfig)
      k get nodes >/dev/null 2>&1 || fail "kubectl still cannot reach $CLUSTER through context $CTX ($(k get nodes 2>&1 | tail -1))"
      pass "you fixed it. Your kubeconfig entry for $CTX pointed at the wrong API server address; the cluster was fine all along." ;;
  esac
}

do_undo() {
  case "$(active_fault)" in
    node-paused)
      docker unpause "$WORKER" >/dev/null 2>&1 || true
      say "The fault: the host $WORKER was paused (docker pause). Repaired with: docker unpause $WORKER" ;;
    stale-kubeconfig)
      kind export kubeconfig --name "$CLUSTER" >/dev/null 2>&1 || true
      say "The fault: the kubeconfig cluster entry for $CTX pointed at the wrong server. Repaired with: kind export kubeconfig --name $CLUSTER" ;;
  esac
  clear_fault
}

main "$@"
