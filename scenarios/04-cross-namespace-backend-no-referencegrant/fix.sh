#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "fix: the TARGET namespace grants the reference (ReferenceGrant lives in sidecar-lab)"
cat <<YAML | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata: { name: allow-lab-apps-routes, namespace: sidecar-lab }
spec:
  from: [{ group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: lab-apps }]
  to:   [{ group: "", kind: Service, name: httpbin }]
YAML
sleep 3
kubectl get httproute shop-mesh -n lab-apps -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")]}'; echo
echo "cleanup: kubectl delete httproute shop-mesh -n lab-apps; kubectl delete referencegrant allow-lab-apps-routes -n sidecar-lab"
