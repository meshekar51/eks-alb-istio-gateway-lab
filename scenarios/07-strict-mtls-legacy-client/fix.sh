#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "fix (ambient way): enroll the CLIENT namespace - no restart, no sidecar"
kubectl label ns legacy-lab istio.io/dataplane-mode=ambient --overwrite; sleep 5
for s in sidecar-lab ambient-lab; do
  printf '  legacy-lab -> httpbin.%s : ' "$s"
  kubectl exec -n legacy-lab deploy/curl -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://httpbin.$s:8000/get" 2>&1 | tail -1
done
echo "undo (keep legacy-lab as the no-mesh baseline): kubectl label ns legacy-lab istio.io/dataplane-mode-"
