#!/usr/bin/env bash
# =============================================================================
#   ███  SPOILER WARNING  ███
#   This script plants the faults of the messy lab. Reading it gives away the
#   answers. Run it, then work ONLY from symptoms + docs/MASTER-TROUBLESHOOTING.md.
#   Progress without spoilers:  make messy-score
#   Give up / reset:            make unmess
# =============================================================================
#  Prerequisite: the GOLDEN lab is deployed and `make test` was green once.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
need kubectl helm aws jq openssl envsubst dig
load_env
require_outputs
kctx_check
M="$LAB_ROOT/messy/manifests"

cat <<EOF
${C_YEL}
  It is Monday morning. Over the weekend "several small changes" were made to
  ${CLUSTER_NAME} by three different people. Nobody wrote anything down.
  Users report: "the shop is down", "the canary never gets traffic",
  "security says the mesh is not enforcing mTLS".  Your job: make it green again.
${C_OFF}
EOF
if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Plant the faults now? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || exit 1
fi
date -u +%FT%TZ > "$STATE_DIR/messy.active"

# ----------------------------------------------------------------- tear the edge down first
log "Weekend change #0: edge rebuilt from scratch"
kubectl delete ingress edge-alb -n lab-gateway --ignore-not-found --wait=true --timeout=5m
for _ in $(seq 1 30); do aws elbv2 describe-load-balancers --names "${CLUSTER_NAME}-edge" >/dev/null 2>&1 || break; sleep 10; done
AUTH_NS=$(dig +short NS "$HOSTED_ZONE" | head -1)
for _ in $(seq 1 30); do [[ -z "$(dig +short "@${AUTH_NS}" "$SHOP_HOST" A)" ]] && break; sleep 10; done

# ----------------------------------------------------------------- AWS / platform
log "Weekend change #1 (platform team)"
old=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace kube-system \
  --service-account aws-load-balancer-controller --query 'associations[0].associationId' --output text)
[[ "$old" != "None" && -n "$old" ]] && aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$old" >/dev/null
aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --namespace kube-system \
  --service-account aws-load-balancer-controler --role-arn "$LBC_ROLE_ARN" >/dev/null
kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system >/dev/null
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=5m >/dev/null

read -r -a PUBS <<<"$PUBLIC_SUBNET_IDS"
aws ec2 delete-tags --resources "${PUBS[1]}" --tags Key=kubernetes.io/role/elb

TMPD=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout "$TMPD/k.pem" -out "$TMPD/c.pem" \
  -subj "/CN=legacy.${DOMAIN}" -addext "subjectAltName=DNS:legacy.${DOMAIN}" 2>/dev/null
BAD_CERT_ARN=$(aws acm import-certificate --certificate "fileb://$TMPD/c.pem" --private-key "fileb://$TMPD/k.pem" \
  --tags Key=Lab,Value=messy Key=Project,Value="$CLUSTER_NAME" Key=Name,Value=legacy-shop-cert \
  --query CertificateArn --output text)
rm -rf "$TMPD"
echo "$BAD_CERT_ARN" > "$STATE_DIR/messy.cert"

TYPO="${HOSTED_ZONE:0:1}${HOSTED_ZONE:2:1}${HOSTED_ZONE:1:1}${HOSTED_ZONE:3}"
helm upgrade external-dns external-dns/external-dns -n external-dns --version "$EXTERNAL_DNS_CHART_VERSION" \
  --reuse-values --set "domainFilters[0]=${TYPO}" --wait >/dev/null

# ----------------------------------------------------------------- Gateway API / apps
log "Weekend change #2 (app team)"
kubectl patch gateway edge -n lab-gateway --type=json \
  -p='[{"op":"replace","path":"/spec/listeners/0/allowedRoutes/namespaces","value":{"from":"Same"}}]' >/dev/null

kubectl apply -f "$(render "$M/shop-v1-pin.yaml")" >/dev/null
sleep 2
kubectl delete httproute shop -n lab-apps --ignore-not-found >/dev/null
kubectl apply -f "$(render "$M/shop.yaml")" >/dev/null

kubectl patch svc podinfo-v2 -n lab-apps --type=merge -p '{"spec":{"selector":{"app":"podinfo","version":"V2"}}}' >/dev/null
kubectl patch httproute api -n lab-apps --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":8080}]' >/dev/null

BAD_INGRESS=$(export ACM_CERT_ARN="$BAD_CERT_ARN"; render "$M/edge-alb.yaml")
kubectl apply -f "$BAD_INGRESS" >/dev/null

# ----------------------------------------------------------------- mesh
log "Weekend change #3 (security team)"
kubectl apply -f "$(render "$LAB_ROOT/k8s/mesh/peerauthentication-strict.yaml")" >/dev/null
kubectl label namespace sidecar-lab istio-injection=enable --overwrite >/dev/null
kubectl rollout restart deploy -n sidecar-lab >/dev/null
kubectl patch deploy curl -n ambient-lab --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"istio.io/dataplane-mode":"none"}}}}}' >/dev/null
kubectl label namespace ambient-lab istio.io/use-waypoint=ambient-waypoint --overwrite >/dev/null
kubectl rollout status deploy -n sidecar-lab --timeout=3m >/dev/null
kubectl rollout status deploy -n ambient-lab --timeout=3m >/dev/null

# don't leave the rendered messy files lying around as hints
rm -rf "$RENDER_DIR/messy"

cat <<EOF

${C_RED}The lab is now messy.${C_OFF}
  Symptoms first:   make test        (bottom-up, stops explaining at the lowest red layer)
  Guided evidence:  make doctor
  Method:           docs/MASTER-TROUBLESHOOTING.md
  Progress score:   make messy-score    (counts remaining faults per layer, no spoilers)
  Answer key:       docs/MESSY-ANSWER-KEY.md   (only when stuck!)
EOF
