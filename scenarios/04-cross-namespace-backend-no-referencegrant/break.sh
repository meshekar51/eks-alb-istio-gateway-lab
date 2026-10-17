#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "shop.<DOMAIN>/mesh -> httpbin in ANOTHER namespace (sidecar-lab)"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: shop-mesh, namespace: lab-apps }
spec:
  parentRefs: [{ name: edge, namespace: lab-gateway }]
  hostnames: ["${SHOP_HOST}"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /mesh } }]
      filters: [{ type: URLRewrite, urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: / } } }]
      backendRefs: [{ name: httpbin, namespace: sidecar-lab, port: 8000 }]
YAML
echo "Broken. curl -s -o /dev/null -w '%{http_code}\n' https://${SHOP_HOST}/mesh/get"
