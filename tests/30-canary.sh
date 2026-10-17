#!/usr/bin/env bash
# Weighted canary: send N requests to shop.<DOMAIN>/api/info and compare the observed
# v1/v2 split to the weights currently configured on the `weighted` rule.
# Tolerance = 4 standard deviations of a binomial(N, p) - wide enough to never flake,
# tight enough to catch "0% canary" or "all traffic on v1" type bugs.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
kctx_check
N="${N:-200}"
V1_VER="${PODINFO_V1_IMAGE##*:}"; V2_VER="${PODINFO_V2_IMAGE##*:}"

read -r W1 W2 < <(kubectl get httproute shop -n lab-apps -o json | jq -r '
  .spec.rules[] | select(.name=="weighted") | .backendRefs
  | [ (map(select(.name=="podinfo-v1"))[0].weight // 1), (map(select(.name=="podinfo-v2"))[0].weight // 0) ] | @tsv')
section "Configured weights: podinfo-v1=$W1  podinfo-v2=$W2  (N=$N)"

v1=0; v2=0; other=0; errors=0; rules_seen=""
for _ in $(seq 1 "$N"); do
  hget "$SHOP_HOST" /api/info
  if [[ "$CODE" != "200" ]]; then errors=$((errors+1)); continue; fi
  r=$(hdr x-lab-rule); [[ "$rules_seen" == *"$r"* ]] || rules_seen+="$r "
  case "$(podinfo_version)" in
    "$V1_VER") v1=$((v1+1)) ;;
    "$V2_VER") v2=$((v2+1)) ;;
    *) other=$((other+1)) ;;
  esac
done

bar() { local n=$1; printf '%*s' $(( n * 50 / N )) '' | tr ' ' '#'; }
printf '  v1 %-8s %4d  %s\n' "$V1_VER" "$v1" "$(bar "$v1")"
printf '  v2 %-8s %4d  %s\n' "$V2_VER" "$v2" "$(bar "$v2")"
printf '  errors        %4d  %s\n' "$errors" "$(bar "$errors")"
printf '  rules seen: %s\n' "$rules_seen"

[[ "$rules_seen" == "weighted " ]] && pass "every request matched the 'weighted' rule" \
  || fail "rules seen: '$rules_seen' (another rule/route is catching default traffic)"
(( errors == 0 )) && pass "no non-200 responses" || fail "$errors/$N requests failed (a backend with weight>0 has no healthy endpoints?)"
(( other == 0 )) || fail "$other responses from an unexpected version"

total=$((W1 + W2)); ok_n=$((v1 + v2))
if (( total == 0 )); then fail "both weights are 0 (all requests should get 500)"; else
  python3 - "$ok_n" "$v2" "$W2" "$total" <<'PY' && pass "v2 share within 4 sigma of $W2/$total" || fail "v2 share outside 4 sigma of $W2/$total (observed $v2/$ok_n)"
import math, sys
n, x, w2, tot = map(int, sys.argv[1:])
p = w2 / tot
if n == 0: sys.exit(1)
if p in (0.0, 1.0): sys.exit(0 if x == round(p * n) else 1)
sd = math.sqrt(n * p * (1 - p))
print(f"  expected {p*n:.1f} +/- {4*sd:.1f}, observed {x}")
sys.exit(0 if abs(x - p * n) <= 4 * sd else 1)
PY
fi

summary "30-canary"
