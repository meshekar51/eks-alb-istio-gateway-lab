#!/usr/bin/env bash
# Goal 2: sidecar vs ambient mTLS, proven three ways:
#   1. behaviour  - who can connect under PERMISSIVE vs STRICT
#   2. identity   - X-Forwarded-Client-Cert (sidecar server) / ztunnel access logs (ambient)
#   3. config     - istioctl proxy-config secret (sidecar) / ztunnel-config workload (ambient)
# NOTE: this test CHANGES state: it removes then re-applies STRICT PeerAuthentication.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
kctx_check
CLIENTS=(sidecar-lab ambient-lab legacy-lab)
SERVERS=(sidecar-lab ambient-lab legacy-lab)

section "Enrollment"
c=$(kubectl get pod -n sidecar-lab -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')
[[ "$c" == *istio-proxy* ]] && pass "sidecar-lab/httpbin has istio-proxy ($c)" || fail "sidecar-lab/httpbin has NO istio-proxy (containers: $c)"
c=$(kubectl get pod -n ambient-lab -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')
[[ "$c" != *istio-proxy* ]] && pass "ambient-lab/httpbin has no sidecar (ambient)" || fail "ambient-lab/httpbin has a sidecar - namespace has BOTH labels?"
ZW=$(istioctl ztunnel-config workload 2>/dev/null)
for app in httpbin curl; do
  proto=$(awk -v app="$app" '$1=="ambient-lab" && $2 ~ "^"app"-" {print $NF; exit}' <<<"$ZW")
  [[ "$proto" == "HBONE" ]] && pass "ztunnel sees ambient-lab/$app as HBONE" || fail "ztunnel sees ambient-lab/$app as '${proto:-absent}' (not enrolled / opted out?)"
done

run_matrix() {
  local phase="$1"
  printf '\n  %-14s' "client \\ srv"; for s in "${SERVERS[@]}"; do printf '%-14s' "$s"; done; echo
  for cns in "${CLIENTS[@]}"; do
    printf '  %-14s' "$cns"
    for sns in "${SERVERS[@]}"; do
      kcurl "$cns" "http://httpbin.${sns}:8000/headers"
      local cell="$CODE"
      [[ "$CODE" == "200" ]] && grep -qi 'X-Forwarded-Client-Cert' "$BODY" && cell="200+XFCC"
      [[ "$CODE" == "000" ]] && cell="RESET"
      printf '%-14s' "$cell"
      MATRIX["$phase/$cns/$sns"]="$cell"
    done; echo
  done
}
declare -A MATRIX

section "Phase A: PERMISSIVE (Istio default) - everything connects, only mesh clients use mTLS"
kubectl delete peerauthentication default -n sidecar-lab --ignore-not-found >/dev/null
kubectl delete peerauthentication default -n ambient-lab --ignore-not-found >/dev/null
sleep 5
run_matrix A
[[ "${MATRIX[A/sidecar-lab/sidecar-lab]}" == "200+XFCC" ]] && pass "sidecar -> sidecar: mTLS (XFCC)" || fail "sidecar -> sidecar: ${MATRIX[A/sidecar-lab/sidecar-lab]} (want 200+XFCC)"
[[ "${MATRIX[A/legacy-lab/sidecar-lab]}" == "200" ]] && pass "legacy -> sidecar: plaintext accepted under PERMISSIVE (no XFCC)" || fail "legacy -> sidecar: ${MATRIX[A/legacy-lab/sidecar-lab]} (want 200 without XFCC)"
[[ "${MATRIX[A/legacy-lab/ambient-lab]}" == "200" ]] && pass "legacy -> ambient: plaintext accepted under PERMISSIVE" || fail "legacy -> ambient: ${MATRIX[A/legacy-lab/ambient-lab]}"
[[ "${MATRIX[A/ambient-lab/ambient-lab]}" == 200* ]] && pass "ambient -> ambient: 200" || fail "ambient -> ambient: ${MATRIX[A/ambient-lab/ambient-lab]}"

section "Phase B: STRICT in sidecar-lab + ambient-lab"
kapply "$LAB_ROOT/k8s/mesh/peerauthentication-strict.yaml" >/dev/null
sleep 8
run_matrix B
for c in sidecar-lab ambient-lab; do
  for s in sidecar-lab ambient-lab; do
    [[ "${MATRIX[B/$c/$s]}" == 200* ]] && pass "$c -> $s (mesh -> STRICT): ${MATRIX[B/$c/$s]}" || fail "$c -> $s (mesh -> STRICT): ${MATRIX[B/$c/$s]} (want 200)"
  done
done
for s in sidecar-lab ambient-lab; do
  [[ "${MATRIX[B/legacy-lab/$s]}" == "RESET" ]] && pass "legacy -> $s REJECTED (STRICT works)" \
    || fail "legacy -> $s = ${MATRIX[B/legacy-lab/$s]} - STRICT is NOT enforced (server not really in the mesh?)"
done
[[ "${MATRIX[B/sidecar-lab/legacy-lab]}" == "200" ]] && pass "sidecar -> legacy: plaintext (auto-mTLS only when the peer can do it)" || note "sidecar -> legacy: ${MATRIX[B/sidecar-lab/legacy-lab]}"

section "Proof: identities"
kcurl sidecar-lab "http://httpbin.sidecar-lab:8000/headers"
xfcc=$(grep -o 'URI=spiffe://[^;"]*' "$BODY" | head -1)
[[ "$xfcc" == "URI=spiffe://cluster.local/ns/sidecar-lab/sa/curl" ]] && pass "sidecar server saw client identity $xfcc" || fail "sidecar server saw '$xfcc'"
if istioctl proxy-config secret deploy/curl -n sidecar-lab 2>/dev/null | grep -q 'default.*ACTIVE.*true'; then
  pass "sidecar-lab/curl Envoy holds an ACTIVE, valid workload cert (istioctl proxy-config secret)"
else note "istioctl proxy-config secret deploy/curl -n sidecar-lab did not show an ACTIVE valid cert (inspect manually)"; fi
kcurl ambient-lab "http://httpbin.ambient-lab:8000/get" >/dev/null
sleep 2
# With the waypoint enrolled, the client's ztunnel tunnels to the WAYPOINT (dst.identity = .../sa/waypoint),
# and the waypoint opens a 2nd HBONE connection to httpbin. Both hops are mTLS with SPIFFE identities.
zl=$(kubectl logs -n istio-system -l app=ztunnel --since=60s --tail=-1 2>/dev/null | grep 'src.identity="spiffe://cluster.local/ns/ambient-lab/sa/curl"' | tail -1)
[[ -n "$zl" ]] && pass "ztunnel access log shows identity spiffe://cluster.local/ns/ambient-lab/sa/curl (HBONE/mTLS)" || note "no ztunnel access log line for ambient-lab/sa/curl in the last 60s (kubectl logs -n istio-system -l app=ztunnel | grep ambient-lab)"
[[ -n "$zl" ]] && printf '    %s\n' "$(grep -o 'src.identity="[^"]*"\|dst.identity="[^"]*"\|dst.hbone_addr=[^ ]*\|dst.service="[^"]*"' <<<"$zl" | tr '\n' ' ')"

summary "40-mtls"
