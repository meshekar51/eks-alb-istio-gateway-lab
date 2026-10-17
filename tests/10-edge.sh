#!/usr/bin/env bash
# L3-L5: ALB, target health, ACM/TLS, Route 53 DNS, HTTP->HTTPS redirect.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
kctx_check
LB_NAME="${CLUSTER_NAME}-edge"

section "Ingress -> ALB"
if [[ -n "$ALB_DNS" ]]; then pass "Ingress edge-alb has address $ALB_DNS"; else
  fail "Ingress edge-alb has NO address (LBC could not build the ALB - kubectl describe ingress edge-alb -n lab-gateway)"; summary "10-edge"; exit 1; fi

LB_JSON=$(aws elbv2 describe-load-balancers --names "$LB_NAME" --output json 2>/dev/null)
LB_ARN=$(jq -r '.LoadBalancers[0].LoadBalancerArn // empty' <<<"$LB_JSON")
[[ -n "$LB_ARN" ]] && pass "ALB $LB_NAME exists" || fail "ALB $LB_NAME not found in ${AWS_REGION}"
state=$(jq -r '.LoadBalancers[0].State.Code // empty' <<<"$LB_JSON")
[[ "$state" == "active" ]] && pass "ALB state active" || fail "ALB state '$state'"
scheme=$(jq -r '.LoadBalancers[0].Scheme // empty' <<<"$LB_JSON")
[[ "$scheme" == "internet-facing" ]] && pass "ALB internet-facing" || fail "ALB scheme '$scheme'"
azs=$(jq -r '.LoadBalancers[0].AvailabilityZones | length' <<<"$LB_JSON" 2>/dev/null)
[[ "${azs:-0}" -ge 2 ]] && pass "ALB spans $azs AZs" || fail "ALB spans ${azs:-0} AZs"

section "Listeners + certificate"
if [[ -n "$LB_ARN" ]]; then
  LIS=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" --output json)
  jq -e '.Listeners[] | select(.Port==443 and .Protocol=="HTTPS")' <<<"$LIS" >/dev/null && pass "HTTPS:443 listener" || fail "no HTTPS:443 listener"
  jq -e '.Listeners[] | select(.Port==80) | .DefaultActions[] | select(.Type=="redirect")' <<<"$LIS" >/dev/null \
    && pass "HTTP:80 default action = redirect" || fail "HTTP:80 does not redirect"
  cert=$(jq -r '.Listeners[] | select(.Port==443) | .Certificates[0].CertificateArn // empty' <<<"$LIS")
  [[ "$cert" == "$ACM_CERT_ARN" ]] && pass "443 uses the Terraform ACM cert" || fail "443 uses cert $cert (expected $ACM_CERT_ARN)"
fi

section "Target health (ALB -> edge-istio pods, health check :15021/healthz/ready)"
TG_ARN=$(kubectl get targetgroupbinding -n lab-gateway -o jsonpath='{.items[0].spec.targetGroupARN}' 2>/dev/null)
if [[ -n "$TG_ARN" ]]; then
  TH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --output json)
  total=$(jq '.TargetHealthDescriptions | length' <<<"$TH")
  healthy=$(jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length' <<<"$TH")
  (( total > 0 && healthy == total )) && pass "$healthy/$total targets healthy" || \
    fail "$healthy/$total targets healthy: $(jq -r '[.TargetHealthDescriptions[] | "\(.Target.Id):\(.Target.Port) \(.TargetHealth.State) \(.TargetHealth.Reason // "") \(.TargetHealth.Description // "")"] | join("; ")' <<<"$TH")"
  hc=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].[HealthCheckPort,HealthCheckPath]' --output text)
  [[ "$hc" == $'15021\t/healthz/ready' ]] && pass "health check 15021 /healthz/ready" || fail "health check is '$hc'"
else
  fail "no TargetGroupBinding in lab-gateway (LBC never created the target group)"
fi

section "DNS (Route 53 via ExternalDNS)"
AUTH_NS=$(dig +short NS "$HOSTED_ZONE" | head -1)
ALB_IPS=$(dig +short "$ALB_DNS" A | sort)
for h in "$SHOP_HOST" "$API_HOST" "$CANARY_HOST"; do
  rec=$(dig +short "@${AUTH_NS}" "$h" A | sort)
  if [[ -z "$rec" ]]; then fail "$h: no A record at authoritative $AUTH_NS"; continue; fi
  if comm -12 <(echo "$rec") <(echo "$ALB_IPS") | grep -q .; then pass "$h -> ALB ($AUTH_NS)"; else
    fail "$h resolves to $(echo "$rec" | tr '\n' ' ')- NOT this ALB ($(echo "$ALB_IPS" | tr '\n' ' '))"; fi
  getent hosts "$h" >/dev/null 2>&1 || note "$h not resolvable from this host's resolver yet (negative caching?)"
done

section "TLS (SNI ${SHOP_HOST}, connecting straight to the ALB)"
CERT_TXT=$(echo | timeout 10 openssl s_client -connect "${ALB_DNS}:443" -servername "$SHOP_HOST" 2>/dev/null)
echo "$CERT_TXT" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -q "\*\.${DOMAIN}" \
  && pass "certificate SAN covers *.${DOMAIN}" || fail "certificate SAN does not cover *.${DOMAIN}: $(echo "$CERT_TXT" | openssl x509 -noout -subject -issuer 2>/dev/null | tr '\n' ' ')"
grep -q "Verify return code: 0" <<<"$CERT_TXT" && pass "chain verifies (public CA)" || fail "chain does not verify: $(grep 'Verify return code' <<<"$CERT_TXT")"

section "HTTP -> HTTPS redirect"
code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 --connect-to "${SHOP_HOST}:80:${ALB_DNS}:80" "http://${SHOP_HOST}/")
[[ "$code" == 301\ https://${SHOP_HOST}* ]] && pass "http:// -> 301 https://" || fail "http:// returned '$code'"

summary "10-edge"
