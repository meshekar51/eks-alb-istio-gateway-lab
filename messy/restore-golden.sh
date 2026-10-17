#!/usr/bin/env bash
# "Reconcile to source of truth": put EVERYTHING back to the golden state from git + Terraform.
# This is the brute-force fix; the targeted fixes are in docs/MESSY-ANSWER-KEY.md.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
load_env
require_outputs
kctx_check
export_tf_vars
K="$LAB_ROOT/k8s"

log "AWS drift -> terraform apply (re-creates the Pod Identity association, re-tags subnets)"
tf apply -input=false -auto-approve
for id in $(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace kube-system \
    --query "associations[?serviceAccount!='aws-load-balancer-controller'].associationId" --output text); do
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$id" >/dev/null && ok "deleted stray association $id"
done
kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=5m

log "Helm releases -> golden values"
helm upgrade external-dns external-dns/external-dns -n external-dns --version "$EXTERNAL_DNS_CHART_VERSION" \
  --reset-values -f "$(render "$LAB_ROOT/platform/external-dns-values.yaml")" --wait

log "Kubernetes objects -> golden manifests"
kubectl delete httproute shop-v1-pin -n lab-apps --ignore-not-found
kapply "$K/00-namespaces.yaml"
kapply "$K/gateway"
kapply "$K/apps"
kapply "$K/routes"
kubectl delete ingress edge-alb -n lab-gateway --ignore-not-found --wait=true
kapply "$K/ingress"
kapply "$K/mesh/peerauthentication-strict.yaml"
kubectl label namespace ambient-lab istio.io/use-waypoint=waypoint --overwrite
# labels added by `kubectl patch` are not in last-applied-configuration -> remove explicitly
kubectl patch deploy curl -n ambient-lab --type=json \
  -p='[{"op":"remove","path":"/spec/template/metadata/labels/istio.io~1dataplane-mode"}]' 2>/dev/null || true
kubectl rollout restart deploy -n sidecar-lab
kubectl rollout status deploy -n sidecar-lab --timeout=3m
kubectl rollout status deploy -n ambient-lab --timeout=3m

log "Waiting for the ALB"
for _ in $(seq 1 60); do [[ -n "$(alb_hostname)" ]] && break; sleep 5; done
ok "ALB: $(alb_hostname)"
if [[ -f "$STATE_DIR/messy.cert" ]]; then
  sleep 30
  aws acm delete-certificate --certificate-arn "$(cat "$STATE_DIR/messy.cert")" && rm -f "$STATE_DIR/messy.cert" \
    || warn "imported cert still attached somewhere; scripts/90-destroy.sh will retry"
fi
rm -f "$STATE_DIR/messy.active"
ok "Golden state re-applied. Give DNS ~1-2 min, then: make test"
