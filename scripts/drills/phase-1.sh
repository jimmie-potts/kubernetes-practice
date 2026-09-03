#!/usr/bin/env bash
# Phase 1 drill: one of three faults breaks Acme's request path. Diagnose it
# hop by hop, fix it, then run:  scripts/drills/phase-1.sh check
PHASE=phase-1
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAULTS=(selector-mismatch wrong-targetport wrong-backend)
URL="http://chat.acme.dc-east.localtest.me:$HTTP_PORT"

preflight() {
  k get svc chat >/dev/null 2>&1 || die "no chat Service in $CTX; finish phase 1 first"
  k get ingress chat >/dev/null 2>&1 || die "no chat Ingress in $CTX; finish phase 1 first"
  [[ -f "$ACME/chat-service.yaml" && -f "$ACME/chat-ingress.yaml" ]] || die "deploy/tenants/acme is missing the phase 1 files"
  [[ "$(http_code -X POST "$URL/v1/completions" -H 'Content-Type: application/json' -d '{"prompt":"drill"}')" == "200" ]] || die "$URL does not answer 200 yet; finish the checkpoint first"
}

do_break() {
  local fault; fault=$(pick_fault "${FAULTS[@]}")
  case "$fault" in
    selector-mismatch) k patch svc chat -p '{"spec":{"selector":{"app":"chat-v2"}}}' >/dev/null ;;
    wrong-targetport) k patch svc chat -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}' >/dev/null ;;
    wrong-backend) k patch ingress chat --type=json -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"chat-api"}]' >/dev/null ;;
  esac
  set_fault "$fault"
  say "Fault injected into $CLUSTER. Acme will notice within a few seconds. Run the checkpoint and describe what you see."
  say "Test your fix with: $0 check    Give up and repair with: $0 undo"
}

completions_ok() { [[ "$(http_code -X POST "$URL/v1/completions" -H 'Content-Type: application/json' -d '{"prompt":"drill"}')" == "200" ]]; }

do_check() {
  local drift=""
  case "$(active_fault)" in
    selector-mismatch) [[ "$(k get svc chat -o jsonpath='{.spec.selector.app}')" == "chat" ]] || drift=1 ;;
    wrong-targetport) [[ "$(k get svc chat -o jsonpath='{.spec.ports[0].targetPort}')" == "8000" ]] || drift=1 ;;
    wrong-backend) [[ "$(k get ingress chat -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}')" == "chat" ]] || drift=1 ;;
  esac
  [[ -z "$drift" ]] || fail "$URL answers HTTP $(http_code "$URL/readyz"), and one object still differs from your files in deploy/tenants/acme; compare each live object with its file"
  wait_for 30 completions_ok || fail "the objects match your files, but $URL still answers HTTP $(http_code "$URL/readyz"); give it a few seconds and check again"
  case "$(active_fault)" in
    selector-mismatch) pass "you fixed it. The Service's selector had drifted to app=chat-v2, so it matched no pods and had no endpoints." ;;
    wrong-targetport) pass "you fixed it. The Service forwarded to container port 8080, but fake-inference listens on 8000, so nginx got connection refused." ;;
    wrong-backend) pass "you fixed it. The Ingress pointed at a Service named chat-api, which does not exist, so nginx had nowhere to send Acme's traffic." ;;
  esac
}

do_undo() {
  case "$(active_fault)" in
    selector-mismatch) k apply -f "$ACME/chat-service.yaml" >/dev/null; say "The fault: the chat Service selector was changed to app=chat-v2 (no pods matched). Repaired with: kubectl apply -f deploy/tenants/acme/chat-service.yaml" ;;
    wrong-targetport) k apply -f "$ACME/chat-service.yaml" >/dev/null; say "The fault: the chat Service targetPort was changed to 8080 (the container listens on 8000). Repaired with: kubectl apply -f deploy/tenants/acme/chat-service.yaml" ;;
    wrong-backend) k apply -f "$ACME/chat-ingress.yaml" >/dev/null; say "The fault: the chat Ingress backend was pointed at a Service named chat-api. Repaired with: kubectl apply -f deploy/tenants/acme/chat-ingress.yaml" ;;
  esac
  clear_fault
}

main "$@"
