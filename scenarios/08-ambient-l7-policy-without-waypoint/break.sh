#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "an L7 ALLOW policy is bound with selector: (=> enforced by ztunnel, which cannot read HTTP)"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: allow-get-only, namespace: ambient-lab }
spec:
  selector: { matchLabels: { app: httpbin } }
  action: ALLOW
  rules: [{ to: [{ operation: { methods: ["GET"] } }] }]
YAML
sleep 5
kubectl exec -n ambient-lab deploy/curl -- curl -sS -m 5 -o /dev/null -w 'GET /get -> %{http_code}\n' http://httpbin.ambient-lab:8000/get 2>&1 | tail -1
