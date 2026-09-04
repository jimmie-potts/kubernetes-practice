#!/usr/bin/env bash
# Phase 3 drill: one of three faults breaks a tenant wall. One blocks the front
# door, one strips a right from Acme's admin, one shrinks Stark's Quota under a
# rolling restart. Diagnose, fix, then run:  scripts/drills/phase-3.sh check
#
# Hint commands the lab points at:
#   kubectl diff -R -f infra/tenants/         (drift between live objects and your files)
#   kubectl -n tnt-stark get events --field-selector reason=FailedCreate
#   kubectl -n tnt-stark describe quota tenant-quota
#   kubectl --kubeconfig acme.kubeconfig auth can-i --list
#   kubectl -n tnt-acme describe networkpolicy allow-ingress-nginx
PHASE=phase-3
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FAULTS=(netpol-blocks-ingress rbac-verb-missing quota-shrunk)
INFRA="$REPO/infra/tenants"
ACME_KUBECONFIG="${FORGE_ACME_KUBECONFIG:-$REPO/acme.kubeconfig}"
CHAT_URL="http://chat.acme.dc-east.localtest.me:$HTTP_PORT"
JARVIS_URL="http://jarvis.stark.dc-east.localtest.me:$HTTP_PORT"

acme_can_list() { kubectl --kubeconfig "$ACME_KUBECONFIG" --context "$CTX" get pods -n tnt-acme >/dev/null 2>&1; }
ready() { [[ "$(http_code "$1/readyz")" == "200" ]]; }

preflight() {
  k get ns tnt-acme tnt-stark >/dev/null 2>&1 || die "namespaces tnt-acme and tnt-stark must exist; finish phase 3 first"
  [[ -f "$INFRA/acme/netpol.yaml" && -f "$INFRA/acme/rbac.yaml" && -f "$INFRA/stark/quota.yaml" ]] || die "infra/tenants is missing the phase 3 files"
  [[ -f "$ACME_KUBECONFIG" ]] || die "no $ACME_KUBECONFIG; finish phase 3 step 6 first"
  acme_can_list || die "the acme kubeconfig cannot list pods in tnt-acme; its token may have expired. Re-run phase 3 step 6 to mint a new one"
  ready "$CHAT_URL" || die "$CHAT_URL/readyz does not answer 200 yet; finish the checkpoint first"
  ready "$JARVIS_URL" || die "$JARVIS_URL/readyz does not answer 200 yet; finish the checkpoint first"
  [[ "$(k -n tnt-stark get deployment jarvis -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}')" == "0" ]] || die "jarvis must roll with maxSurge 0 (phase 3 step 5); the Quota fault relies on it"
  k -n tnt-stark rollout status deployment/jarvis --timeout=60s >/dev/null 2>&1 || die "a jarvis rollout is still in progress; let it settle first"
}

do_break() {
  local fault; fault=$(pick_fault "${FAULTS[@]}")
  case "$fault" in
    netpol-blocks-ingress)
      k -n tnt-acme patch networkpolicy allow-ingress-nginx --type=json -p '[{"op":"replace","path":"/spec/ingress/0/from/0/namespaceSelector/matchLabels","value":{"kubernetes.io/metadata.name":"ingress-nginx-legacy"}}]' >/dev/null ;;
    rbac-verb-missing)
      k -n tnt-acme patch role tenant-admin --type=json -p '[{"op":"replace","path":"/rules/0/verbs","value":["get","watch"]}]' >/dev/null ;;
    quota-shrunk)
      k -n tnt-stark patch resourcequota tenant-quota -p '{"spec":{"hard":{"requests.cpu":"500m"}}}' >/dev/null
      k -n tnt-stark rollout restart deployment jarvis >/dev/null ;;
  esac
  set_fault "$fault"
  say "Fault injected into $CLUSTER. Give it a minute, then walk both tenants: their front doors, their admins, their rollouts. Describe what you see."
  say "Test your fix with: $0 check    Give up and repair with: $0 undo"
}

do_check() {
  case "$(active_fault)" in
    netpol-blocks-ingress)
      [[ "$(k -n tnt-acme get networkpolicy allow-ingress-nginx -o jsonpath='{.spec.ingress[0].from[0].namespaceSelector.matchLabels.kubernetes\.io/metadata\.name}')" == "ingress-nginx" ]] || fail "$CHAT_URL does not answer within 10 s (curl reports $(http_code "$CHAT_URL/readyz")), and one object still differs from your files in infra/tenants; kubectl diff -R shows which"
      wait_for 30 ready "$CHAT_URL" || fail "the objects match your files, but $CHAT_URL still answers HTTP $(http_code "$CHAT_URL/readyz"); give it a few seconds and check again"
      pass "you fixed it. The allow-ingress-nginx policy in tnt-acme selected a namespace that does not exist, so the default-deny wall also shut out the front door and nginx timed out reaching chat." ;;
    rbac-verb-missing)
      [[ "$(k -n tnt-acme get role tenant-admin -o jsonpath='{.rules[0].verbs}')" == *'"list"'* && "$(k -n tnt-acme get role tenant-admin -o jsonpath='{.rules[0].verbs}')" == *'"delete"'* ]] || fail "Acme's admin still cannot do everything the file grants; one object differs from your files in infra/tenants; kubectl diff -R shows which"
      wait_for 20 acme_can_list || fail "the Role matches your file, but the acme kubeconfig still cannot list pods; give it a few seconds and check again"
      pass "you fixed it. The first rule of the tenant-admin Role in tnt-acme had lost most of its verbs, so Acme's admin could get single pods, Services, ConfigMaps, and Secrets but not list, create, or delete them." ;;
    quota-shrunk)
      local updated; updated=$(k -n tnt-stark get deploy jarvis -o jsonpath='{.status.updatedReplicas}'); updated=${updated:-0}
      [[ "$(k -n tnt-stark get resourcequota tenant-quota -o jsonpath='{.spec.hard.requests\.cpu}')" == "1500m" ]] || fail "jarvis has $updated of $(k -n tnt-stark get deploy jarvis -o jsonpath='{.spec.replicas}') pods on the new template, and one object still differs from your files in infra/tenants; kubectl diff -R shows which"
      k -n tnt-stark rollout status deployment/jarvis --timeout=180s >/dev/null 2>&1 || fail "the Quota matches your file, but the jarvis rollout has not converged yet: $(k -n tnt-stark get pods -l app=jarvis --no-headers | awk '{print $1": "$3}' | paste -sd ', '). The ReplicaSet's retry delay doubles after every refusal; check again in a couple of minutes, or rollout restart jarvis to start a fresh ReplicaSet"
      wait_for 30 ready "$JARVIS_URL" || fail "the rollout converged, but $JARVIS_URL still answers HTTP $(http_code "$JARVIS_URL/readyz")"
      pass "you fixed it. Stark's Quota had shrunk to 500m of CPU requests, below what jarvis already used, so the restarted rollout retired one old pod and then could not create a new one; a single old pod kept serving." ;;
  esac
}

do_undo() {
  local fault; fault=$(active_fault)
  k apply -R -f "$INFRA/" >/dev/null
  case "$fault" in
    netpol-blocks-ingress) say "The fault: the allow-ingress-nginx NetworkPolicy in tnt-acme was pointed at a namespace label that matches nothing. Repaired with: kubectl apply -R -f infra/tenants/" ;;
    rbac-verb-missing) say "The fault: the first rule of the tenant-admin Role in tnt-acme was cut down to get and watch. Repaired with: kubectl apply -R -f infra/tenants/" ;;
    quota-shrunk)
      k -n tnt-stark rollout status deployment/jarvis --timeout=180s >/dev/null 2>&1 || true
      say "The fault: Stark's ResourceQuota was shrunk to requests.cpu 500m and jarvis was restarted onto it. Repaired with: kubectl apply -R -f infra/tenants/ (the ReplicaSet retries on its own once the Quota is back)" ;;
  esac
  clear_fault
}

main "$@"
