#!/usr/bin/env bash
# Platform layer, in dependency order:
#   1. Gateway API CRDs (standard channel)      - must exist BEFORE Istio and the LBC start
#   2. AWS Load Balancer Controller (Helm)      - Pod Identity creds, explicit region + VPC
#   3. Istio (ambient profile: istiod + CNI + ztunnel; sidecar injection still available)
#   4. ExternalDNS (Helm)                        - Route 53 records for the ALB
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl helm istioctl aws jq envsubst
load_env
require_outputs
kctx_check

# ------------------------------------------------------------------ 1. Gateway API CRDs
log "Gateway API CRDs ${GATEWAY_API_VERSION} (standard channel)"
run kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl wait --for=condition=Established --timeout=60s \
  crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/referencegrants.gateway.networking.k8s.io
ok "bundle-version: $(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"

# ------------------------------------------------------------------ 2. AWS LBC
log "AWS Load Balancer Controller chart ${LBC_CHART_VERSION}"
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --query "associations[?namespace=='kube-system' && serviceAccount=='aws-load-balancer-controller'].associationId" \
  --output text | grep -q . || die "No Pod Identity association for kube-system/aws-load-balancer-controller (terraform apply?)"
ok "Pod Identity association present"
run helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
run helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system --version "$LBC_CHART_VERSION" \
  -f "$(render "$LAB_ROOT/platform/lbc-values.yaml")" \
  --wait --timeout 10m
ARGS=$(kubectl get deploy aws-load-balancer-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}')
grep -q -- "--aws-region=${AWS_REGION}" <<<"$ARGS" || die "LBC is not pinned to region ${AWS_REGION}: $ARGS"
grep -q -- "--aws-vpc-id=${VPC_ID}" <<<"$ARGS" || die "LBC is not pinned to VPC ${VPC_ID}: $ARGS"
ok "LBC args pinned: region=${AWS_REGION} vpc=${VPC_ID}"
# Pod Identity creds are injected at pod creation; prove the env var is there.
POD=$(kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD" -n kube-system -o jsonpath='{.spec.containers[0].env[*].name}' | grep -q AWS_CONTAINER_CREDENTIALS_FULL_URI \
  && ok "LBC pod has Pod Identity credentials (AWS_CONTAINER_CREDENTIALS_FULL_URI)" \
  || warn "LBC pod has NO Pod Identity env - restart it after fixing the association: kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller"

# ------------------------------------------------------------------ 3. Istio
log "Istio ${ISTIO_VERSION} (ambient profile)"
istioctl version --remote=false --short 2>/dev/null | grep -q "$ISTIO_VERSION" || warn "istioctl client is not ${ISTIO_VERSION}"
run istioctl x precheck || warn "precheck reported issues (read them)"
run istioctl install -y -f "$LAB_ROOT/platform/istio/istio-ambient.yaml"
kubectl rollout status deploy/istiod -n istio-system --timeout=5m
kubectl rollout status ds/istio-cni-node -n istio-system --timeout=5m
kubectl rollout status ds/ztunnel -n istio-system --timeout=5m
for gc in istio istio-waypoint; do
  for _ in $(seq 1 30); do kubectl get gatewayclass "$gc" >/dev/null 2>&1 && break; sleep 2; done
  if kubectl wait --for=condition=Accepted "gatewayclass/$gc" --timeout=120s >/dev/null 2>&1; then
    ok "GatewayClass $gc Accepted"
  else
    die "GatewayClass $gc not Accepted - check: kubectl logs -n istio-system deploy/istiod | grep -i gateway"
  fi
done
kubectl get gatewayclass

# ------------------------------------------------------------------ 4. ExternalDNS
log "ExternalDNS chart ${EXTERNAL_DNS_CHART_VERSION}"
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f - >/dev/null
run helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update >/dev/null
run helm upgrade --install external-dns external-dns/external-dns \
  --namespace external-dns --version "$EXTERNAL_DNS_CHART_VERSION" \
  -f "$(render "$LAB_ROOT/platform/external-dns-values.yaml")" \
  --wait --timeout 5m

log "Platform summary"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n istio-system
kubectl get pods -n external-dns
ok "Platform ready. Next: make apps"
