#!/usr/bin/env bash
# Deploy the GOLDEN lab: namespaces, apps, edge Gateway, HTTPRoutes, ALB Ingress, mesh labs.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl envsubst dig
load_env
require_outputs
kctx_check
K="$LAB_ROOT/k8s"

log "Namespaces"
kapply "$K/00-namespaces.yaml"

log "Apps (lab-apps, sidecar mode)"
kapply "$K/apps"
for d in podinfo-v1 podinfo-v2 httpbin; do kubectl rollout status "deploy/$d" -n lab-apps --timeout=5m; done
kubectl get pods -n lab-apps -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,CONTAINERS:.spec.containers[*].name,INIT:.spec.initContainers[*].name' || true

log "Edge Gateway (Istio, Gateway API)"
kapply "$K/gateway"
kubectl wait --for=condition=Programmed gateway/edge -n lab-gateway --timeout=5m
kubectl rollout status deploy/edge-istio -n lab-gateway --timeout=5m
[[ "$(kubectl get svc edge-istio -n lab-gateway -o jsonpath='{.spec.type}')" == "ClusterIP" ]] \
  && ok "edge-istio Service is ClusterIP (no extra AWS load balancer)" \
  || die "edge-istio Service is not ClusterIP - the parametersRef overlay was not applied"

log "HTTPRoutes"
kapply "$K/routes"
sleep 3
kubectl get httproute -n lab-apps -o custom-columns='ROUTE:.metadata.name,HOSTS:.spec.hostnames,ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status,REFS:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status' || true

log "ALB Ingress"
kapply "$K/ingress"
echo "  waiting for the ALB address (2-4 min on first create)..."
for _ in $(seq 1 60); do
  ALB=$(alb_hostname); [[ -n "$ALB" ]] && break; sleep 5
done
[[ -n "${ALB:-}" ]] || { kubectl describe ingress edge-alb -n lab-gateway | tail -20; die "No ALB hostname. See docs/MASTER-TROUBLESHOOTING.md L3."; }
ok "ALB: $ALB"

log "Mesh labs: sidecar-lab / ambient-lab / legacy-lab"
MESH=$(render "$K/mesh/workloads.yaml")
for ns in sidecar-lab ambient-lab legacy-lab; do
  run kubectl apply -n "$ns" -f "$MESH"
done
for ns in sidecar-lab ambient-lab legacy-lab; do
  kubectl rollout status deploy/httpbin -n "$ns" --timeout=5m
  kubectl rollout status deploy/curl -n "$ns" --timeout=5m
done

log "Ambient waypoint + L7 policy (ambient-lab)"
kapply "$K/mesh/ambient-waypoint.yaml"
kubectl wait --for=condition=Programmed gateway/waypoint -n ambient-lab --timeout=3m
run kubectl label namespace ambient-lab istio.io/use-waypoint=waypoint --overwrite

log "Waiting for DNS (ExternalDNS -> Route 53). Asking the zone's authoritative NS directly."
AUTH_NS=$(dig +short NS "$HOSTED_ZONE" | head -1)
for _ in $(seq 1 40); do
  got=$(dig +short "@${AUTH_NS:-8.8.8.8}" "$SHOP_HOST" A | head -1)
  [[ -n "$got" ]] && break; sleep 6
done
[[ -n "${got:-}" ]] && ok "$SHOP_HOST -> $got (authoritative)" || warn "DNS record not visible yet - check: kubectl logs -n external-dns deploy/external-dns"

cat <<EOF

${C_GRN}Golden lab deployed.${C_OFF}
  Browser:  https://${SHOP_HOST}/          (weighted v1/v2 - refresh a few times)
            https://${CANARY_HOST}/        (always v2)
            https://${SHOP_HOST}/httpbin/headers   (see X-Forwarded-Client-Cert = gateway->app mTLS)
            https://${API_HOST}/headers
  Tests:    make test
  Doctor:   make doctor
EOF
