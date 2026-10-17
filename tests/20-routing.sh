#!/usr/bin/env bash
# L6-L8: Gateway API status + host / path / header / query routing through the REAL edge
# (Browser path: DNS -> ALB -> edge-istio -> HTTPRoute rule -> Service -> Pod).
# Each rule sets the response header x-lab-rule, so we assert WHICH rule matched,
# and podinfo's JSON "version" tells us WHICH version answered.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
kctx_check
V2_VER="${PODINFO_V2_IMAGE##*:}"

section "Gateway + HTTPRoute status"
s=$(kubectl get gateway edge -n lab-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
[[ "$s" == "True" ]] && pass "Gateway edge Programmed" || fail "Gateway edge Programmed=$s"
att=$(kubectl get gateway edge -n lab-gateway -o jsonpath='{.status.listeners[0].attachedRoutes}' 2>/dev/null)
[[ "${att:-0}" -ge 3 ]] && pass "listener http attachedRoutes=$att" || fail "listener http attachedRoutes=${att:-0} (expected >=3)"
for r in shop api canary-preview; do
  a=$(kubectl get httproute "$r" -n lab-apps -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  rr=$(kubectl get httproute "$r" -n lab-apps -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null)
  if [[ "$a" == "True" && "$rr" == "True" ]]; then pass "HTTPRoute $r Accepted+ResolvedRefs"; else
    fail "HTTPRoute $r Accepted=$a ResolvedRefs=$rr ($(kubectl get httproute "$r" -n lab-apps -o jsonpath='{range .status.parents[0].conditions[?(@.status=="False")]}{.reason}: {.message} {end}' 2>/dev/null))"; fi
done
others=$(kubectl get httproute -A --no-headers 2>/dev/null | grep -vcE '^lab-apps +(shop|api|canary-preview) ' || true)
[[ "${others:-0}" -eq 0 ]] && pass "no unexpected HTTPRoutes in the cluster" || note "$others other HTTPRoute(s) exist - could they shadow ours? kubectl get httproute -A"

# assert_route <desc> <host> <path> <want-rule> <want-version|-> [curl args]
assert_route() {
  local desc="$1" host="$2" path="$3" want_rule="$4" want_ver="$5"; shift 5
  hget "$host" "$path" "$@"
  local rule ver; rule=$(hdr x-lab-rule); ver=$(podinfo_version)
  if [[ "$CODE" != "200" ]]; then
    fail "$desc: HTTP $CODE (server: $(hdr server), rule: ${rule:-none})"; return
  fi
  if [[ "$rule" != "$want_rule" ]]; then fail "$desc: matched rule '${rule:-none}', expected '$want_rule'"; return; fi
  if [[ "$want_ver" != "-" && "$ver" != "$want_ver" ]]; then fail "$desc: version '$ver', expected '$want_ver'"; return; fi
  pass "$desc -> rule=$rule${ver:+ version=$ver}"
}

section "Host-based"
assert_route "api host       https://${API_HOST}/get" "$API_HOST" /get api-host -
grep -q '"url"' "$BODY" && pass "  httpbin answered (JSON with url)" || fail "  body is not httpbin JSON"
assert_route "canary host    https://${CANARY_HOST}/" "$CANARY_HOST" / canary-host "$V2_VER"

section "Path-based (+ URLRewrite)"
assert_route "path /httpbin  https://${SHOP_HOST}/httpbin/headers" "$SHOP_HOST" /httpbin/headers path-httpbin -
grep -qi '"X-Forwarded-Client-Cert"' "$BODY" \
  && pass "  XFCC present at httpbin -> gateway->app hop is Istio mTLS ($(grep -o 'URI=spiffe://[^;"]*' "$BODY" | head -1))" \
  || fail "  no X-Forwarded-Client-Cert at httpbin: gateway->app hop is NOT mTLS (sidecar missing?)"
assert_route "path /v2       https://${SHOP_HOST}/v2" "$SHOP_HOST" /v2 path-v2 "$V2_VER"

section "Header-based"
assert_route "x-canary: true" "$SHOP_HOST" /api/info header-canary "$V2_VER" -H 'x-canary: true'
assert_route "X-CANARY: true (name is case-insensitive)" "$SHOP_HOST" /api/info header-canary "$V2_VER" -H 'X-CANARY: true'
hget "$SHOP_HOST" /api/info -H 'x-canary: True'
[[ "$(hdr x-lab-rule)" == "weighted" ]] && pass "x-canary: True (value is case-SENSITIVE) falls through to weighted" \
  || fail "x-canary: True matched '$(hdr x-lab-rule)', expected weighted"

section "Query-param-based"
assert_route "?version=v2" "$SHOP_HOST" "/api/info?version=v2" query-canary "$V2_VER"
assert_route "header beats query when both present" "$SHOP_HOST" "/api/info?version=v2" header-canary "$V2_VER" -H 'x-canary: true'

section "Default (weighted canary)"
assert_route "no header/param" "$SHOP_HOST" /api/info weighted -

section "Negative: unknown host must be rejected by Envoy (not the ALB)"
hget "nothing-here.${DOMAIN}" / --connect-to "nothing-here.${DOMAIN}:443:${ALB_DNS}:443"
srv=$(hdr server)
[[ "$CODE" == "404" && "$srv" == "istio-envoy" ]] && pass "unknown host -> 404 from istio-envoy (gateway reached, no route)" \
  || fail "unknown host -> $CODE server=$srv (expected 404 istio-envoy)"

summary "20-routing"
