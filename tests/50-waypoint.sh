#!/usr/bin/env bash
# Ambient L7: the waypoint enforces an HTTP-path DENY that ztunnel alone cannot.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
kctx_check

section "Waypoint wiring"
s=$(kubectl get gateway waypoint -n ambient-lab -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
[[ "$s" == "True" ]] && pass "waypoint Gateway Programmed" || fail "waypoint Gateway Programmed=$s"
lbl=$(kubectl get ns ambient-lab -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')
[[ "$lbl" == "waypoint" ]] && pass "ambient-lab labelled istio.io/use-waypoint=waypoint" || fail "ambient-lab istio.io/use-waypoint='$lbl' (must name an existing waypoint)"
wp=$(istioctl ztunnel-config service 2>/dev/null | awk '$1=="ambient-lab" && $2=="httpbin" {print $4; exit}')   # NAMESPACE NAME VIP WAYPOINT ENDPOINTS
[[ "$wp" == "waypoint" ]] && pass "ztunnel routes httpbin.ambient-lab via waypoint" || fail "ztunnel shows waypoint='${wp:-none}' for httpbin.ambient-lab (traffic BYPASSES the waypoint)"

section "L7 policy (DENY /forbidden) - enforced by the waypoint"
kcurl ambient-lab "http://httpbin.ambient-lab:8000/get"
[[ "$CODE" == "200" ]] && pass "ambient client GET /get -> 200" || fail "ambient client GET /get -> $CODE $KCURL_ERR"
kcurl ambient-lab "http://httpbin.ambient-lab:8000/forbidden"
[[ "$CODE" == "403" ]] && pass "ambient client GET /forbidden -> 403 (RBAC: access denied by waypoint)" || fail "ambient client GET /forbidden -> $CODE (expected 403)"
kcurl sidecar-lab "http://httpbin.ambient-lab:8000/forbidden"
[[ "$CODE" == "403" ]] && pass "sidecar client GET /forbidden -> 403 (sidecars also honour the destination waypoint)" || note "sidecar client GET /forbidden -> $CODE"

section "Policy status"
kubectl get authorizationpolicy deny-forbidden-path -n ambient-lab -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}) {.message}{"\n"}{end}' 2>/dev/null | sed 's/^/    /'

summary "50-waypoint"
