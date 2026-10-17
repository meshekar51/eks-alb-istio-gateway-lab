#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "a new team publishes promo.${HOSTED_ZONE} on the shared edge"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: promo, namespace: lab-apps }
spec:
  parentRefs: [{ name: edge, namespace: lab-gateway }]
  hostnames: ["promo.${HOSTED_ZONE}"]
  rules: [{ backendRefs: [{ name: podinfo-v1, port: 80 }] }]
YAML
echo "Broken. curl --connect-to promo.${HOSTED_ZONE}:443:\$(kubectl get ingress edge-alb -n lab-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):443 -k https://promo.${HOSTED_ZONE}/"
