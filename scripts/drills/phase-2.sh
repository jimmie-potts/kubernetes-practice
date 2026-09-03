#!/usr/bin/env bash
# Phase 2 drill: one of three faults lands on chat. Two of them stall a rollout
# without touching Acme's traffic; one slows every request. Diagnose, fix, then
# run:  scripts/drills/phase-2.sh check
PHASE=phase-2
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAULTS=(readiness-path cpu-request slow-config)
URL="http://chat.acme.dc-east.localtest.me:$HTTP_PORT"
CONTAINER='.spec.template.spec.containers[0]'

preflight() {
  k get deployment chat >/dev/null 2>&1 || die "no chat Deployment in $CTX; finish phase 2 first"
  k get configmap chat-config >/dev/null 2>&1 || die "no chat-config ConfigMap in $CTX; finish phase 2 step 1 first"
  [[ "$(k get deployment chat -o jsonpath="{${CONTAINER}.readinessProbe.httpGet.path}")" == "/readyz" ]] || die "chat has no /readyz readiness probe; finish phase 2 step 2 first"
  [[ -n "$(k get deployment chat -o jsonpath="{${CONTAINER}.resources.requests.cpu}")" && -n "$(k get deployment chat -o jsonpath="{${CONTAINER}.resources.limits.cpu}")" ]] || die "chat has no CPU request and limit; finish phase 2 step 3 first"
  [[ -f "$ACME/chat-deployment.yaml" && -f "$ACME/chat-config.yaml" ]] || die "deploy/tenants/acme is missing the phase 2 files"
  k rollout status deployment/chat --timeout=60s >/dev/null 2>&1 || die "a chat rollout is still in progress; let it settle first"
}

do_break() {
  local fault; fault=$(pick_fault "${FAULTS[@]}")
  case "$fault" in
    readiness-path) k patch deployment chat --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready"}]' >/dev/null ;;
    cpu-request) k patch deployment chat --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"1000"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"1000"}]' >/dev/null ;;
    slow-config) k patch configmap chat-config -p '{"data":{"SIMULATED_DELAY_MS":"4000"}}' >/dev/null; k rollout restart deployment chat >/dev/null ;;
  esac
  set_fault "$fault"
  say "Fault injected into $CLUSTER. Give it a minute, then check Acme's traffic and the Deployment, and describe what you see."
  say "Test your fix with: $0 check    Give up and repair with: $0 undo"
}

running_pods() {
  k get pods -l app=chat --field-selector=status.phase=Running --no-headers \
    -o custom-columns=NAME:.metadata.name,DEL:.metadata.deletionTimestamp | awk '$2=="<none>"{print $1}'
}
pods_fast() {
  local p v
  for p in $(running_pods); do
    v=$(k exec "$p" -- printenv SIMULATED_DELAY_MS 2>/dev/null || echo "?")
    [[ "$v" == "150" ]] || return 1
  done
}
completions_fast() {
  local out; out=$(curl -s -o /dev/null -m 10 -w '%{http_code} %{time_total}' -X POST "$URL/v1/completions" -H 'Content-Type: application/json' -d '{"prompt":"drill"}' 2>/dev/null || echo "000 99")
  awk -v code="${out% *}" -v t="${out#* }" 'BEGIN{exit !(code=="200" && t+0 < 2.0)}'
}

do_check() {
  case "$(active_fault)" in
    readiness-path)
      [[ "$(k get deployment chat -o jsonpath="{${CONTAINER}.readinessProbe.httpGet.path}")" == "/readyz" ]] || fail "one object still differs from your files in deploy/tenants/acme; compare each live object with its file" ;;
    cpu-request)
      [[ "$(k get deployment chat -o jsonpath="{${CONTAINER}.resources.requests.cpu}")" == "100m" && "$(k get deployment chat -o jsonpath="{${CONTAINER}.resources.limits.cpu}")" == "500m" ]] || fail "one object still differs from your files in deploy/tenants/acme; compare each live object with its file" ;;
    slow-config)
      [[ "$(k get configmap chat-config -o jsonpath='{.data.SIMULATED_DELAY_MS}')" == "150" ]] || fail "one object still differs from your files in deploy/tenants/acme; compare each live object with its file"
      k rollout status deployment/chat --timeout=90s >/dev/null 2>&1 || fail "the chat rollout has not converged yet; give it a minute and check again"
      pods_fast || fail "the ConfigMap is right, but running pods still carry the old value. Remember what the lab said about env vars and restarts." ;;
  esac
  k rollout status deployment/chat --timeout=90s >/dev/null 2>&1 || fail "the chat rollout has not converged: $(k get pods -l app=chat --no-headers | awk '{print $1": "$3}' | paste -sd ', ')"
  wait_for 30 completions_fast || fail "$URL is not answering 200 within two seconds yet; give it a few seconds and check again"
  case "$(active_fault)" in
    readiness-path) pass "you fixed it. The readiness probe path had drifted to /ready (a 404), so the new pod never became Ready and the rollout stalled while the old pods kept serving." ;;
    cpu-request) pass "you fixed it. The CPU request and limit had drifted to 1000 cores, so no node could fit the new pod; it stayed Pending and the rollout stalled while the old pods kept serving." ;;
    slow-config) pass "you fixed it. SIMULATED_DELAY_MS had drifted to 4000 in the ConfigMap and the pods were restarted onto it; fixing the ConfigMap alone changes nothing until the pods roll again." ;;
  esac
}

do_undo() {
  local fault; fault=$(active_fault)
  k apply -f "$ACME/" >/dev/null
  [[ "$fault" == "slow-config" ]] && k rollout restart deployment chat >/dev/null
  k rollout status deployment/chat --timeout=120s >/dev/null 2>&1 || true
  case "$fault" in
    readiness-path) say "The fault: the readiness probe path was changed to /ready. Repaired with: kubectl apply -f deploy/tenants/acme/" ;;
    cpu-request) say "The fault: the CPU request and limit were changed to 1000 cores. Repaired with: kubectl apply -f deploy/tenants/acme/" ;;
    slow-config) say "The fault: SIMULATED_DELAY_MS was set to 4000 in the ConfigMap and the pods restarted onto it. Repaired with: kubectl apply -f deploy/tenants/acme/ && kubectl rollout restart deployment chat" ;;
  esac
  clear_fault
}

main "$@"
