#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "fix: bind the L7 policy to the Service (targetRefs) so the WAYPOINT enforces it"
kubectl delete authorizationpolicy allow-get-only -n ambient-lab --ignore-not-found
cat <<YAML | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: allow-get-only, namespace: ambient-lab }
spec:
  targetRefs: [{ kind: Service, group: "", name: httpbin }]
  action: ALLOW
  rules: [{ to: [{ operation: { methods: ["GET"] } }] }]
YAML
sleep 5
kubectl exec -n ambient-lab deploy/curl -- curl -sS -m 5 -o /dev/null -w 'GET  /get  -> %{http_code}\n' http://httpbin.ambient-lab:8000/get
kubectl exec -n ambient-lab deploy/curl -- curl -sS -m 5 -o /dev/null -w 'POST /post -> %{http_code}\n' -X POST http://httpbin.ambient-lab:8000/post
echo "cleanup: kubectl delete authorizationpolicy allow-get-only -n ambient-lab"
