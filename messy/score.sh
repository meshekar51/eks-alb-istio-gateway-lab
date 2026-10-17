#!/usr/bin/env bash
# Messy-lab scoreboard. Counts remaining planted faults PER LAYER without naming them.
#   make messy-score            -> counts only
#   messy/score.sh --reveal     -> names the remaining faults (spoiler!)
set -uo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
load_env
kctx_check
REVEAL=0; [[ "${1:-}" == "--reveal" ]] && REVEAL=1
read -r -a PUBS <<<"${PUBLIC_SUBNET_IDS:-}"

jp() { kubectl get "$@" 2>/dev/null; }   # tolerant kubectl get

# Each f_Mxx returns 0 (true) while the fault is STILL PRESENT.
f_M01() {
  local n; n=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace kube-system \
    --service-account aws-load-balancer-controller --query 'length(associations)' --output text 2>/dev/null)
  [[ "$n" != "1" ]] && return 0
  local p; for p in $(jp pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o name); do
    jp "$p" -n kube-system -o jsonpath='{.spec.containers[0].env[*].name}' | grep -q AWS_CONTAINER_CREDENTIALS_FULL_URI || return 0
  done
  return 1
}
f_M02() { [[ -n "${PUBS[1]:-}" ]] && [[ "$(aws ec2 describe-subnets --subnet-ids "${PUBS[1]}" \
            --query "length(Subnets[0].Tags[?Key=='kubernetes.io/role/elb'])" --output text 2>/dev/null)" == "0" ]]; }
f_M03() { [[ "$(jp ingress edge-alb -n lab-gateway -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}')" != "$ACM_CERT_ARN" ]]; }
f_M04() { ! jp deploy external-dns -n external-dns -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- "--domain-filter=${HOSTED_ZONE}\""; }
f_M05() { [[ "$(jp ingress edge-alb -n lab-gateway -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}')" != "edge-istio" ]]; }
f_M06() { [[ "$(jp ingress edge-alb -n lab-gateway -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/healthcheck-path}')" != "/healthz/ready" ]]; }
f_M07() { [[ "$(jp gateway edge -n lab-gateway -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}')" != "Selector" ]]; }
f_M08() { jp httproute shop-v1-pin -n lab-apps >/dev/null; }
f_M09() { [[ "$(jp svc podinfo-v2 -n lab-apps -o jsonpath='{.spec.selector.version}')" != "v2" ]]; }
f_M10() { [[ "$(jp httproute api -n lab-apps -o jsonpath='{.spec.rules[0].backendRefs[0].port}')" != "8000" ]]; }
f_M11() { ! jp httproute shop -n lab-apps -o json | jq -e '.spec.rules[] | select(.name=="path-v2") | .filters[]? | select(.type=="URLRewrite")' >/dev/null; }
f_M12() { ! jp httproute shop -n lab-apps -o json | jq -e '.spec.rules[] | select(.name=="header-canary") | .matches[0].headers[]? | select((.name|ascii_downcase)=="x-canary")' >/dev/null; }
f_M13() { [[ "$(jp ns sidecar-lab -o jsonpath='{.metadata.labels.istio-injection}')" != "enabled" ]] && return 0
          ! jp pod -n sidecar-lab -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}' | grep -q istio-proxy; }
f_M14() { [[ -n "$(jp deploy curl -n ambient-lab -o jsonpath='{.spec.template.metadata.labels.istio\.io/dataplane-mode}')" ]]; }
f_M15() { [[ "$(jp ns ambient-lab -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')" != "waypoint" ]]; }

declare -A REMAIN; OPEN=()
check() { local layer="$1" id="$2" desc="$3"
  if "f_$id"; then REMAIN[$layer]=$(( ${REMAIN[$layer]:-0} + 1 )); OPEN+=("$layer  $id  $desc"); fi; }

check L1-controllers M01 "LBC has no AWS credentials"
check L1-controllers M04 "ExternalDNS zone filter"
check L3-alb         M02 "public subnet discovery"
check L3-alb         M05 "Ingress backend Service"
check L3-alb         M03 "listener certificate"
check L3-alb         M06 "target health check"
check L4-gateway     M07 "listener allowedRoutes"
check L5-routes      M08 "a route shadowing shop"
check L5-routes      M11 "path rule /v2"
check L5-routes      M12 "header rule"
check L6-backends    M09 "Service without endpoints"
check L6-backends    M10 "backendRef port"
check L7-mesh        M13 "sidecar-lab enrollment"
check L7-mesh        M14 "ambient-lab client enrollment"
check L7-mesh        M15 "ambient waypoint wiring"

total=15; left=${#OPEN[@]}
printf '\n  Messy lab scoreboard: %s%d / %d fixed%s\n\n' "$C_GRN" $(( total - left )) "$total" "$C_OFF"
for l in L1-controllers L3-alb L4-gateway L5-routes L6-backends L7-mesh; do
  n=${REMAIN[$l]:-0}
  if (( n == 0 )); then printf '   %-15s %sclean%s\n' "$l" "$C_GRN" "$C_OFF"
  else printf '   %-15s %s%d fault(s) remaining%s\n' "$l" "$C_RED" "$n" "$C_OFF"; fi
done
if (( REVEAL && left > 0 )); then echo; printf '   %s\n' "${OPEN[@]}"; fi
if (( left == 0 )); then
  echo; ok "All planted faults fixed. Now prove it end-to-end: make test"
  [[ -f "$STATE_DIR/messy.cert" ]] && echo "  Clean-up: aws acm delete-certificate --certificate-arn $(cat "$STATE_DIR/messy.cert")   (after the ALB stopped using it)"
fi
