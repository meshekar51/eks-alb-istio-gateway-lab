#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "security enables STRICT; the legacy batch job (legacy-lab) still calls both servers"
kapply "$LAB_ROOT/k8s/mesh/peerauthentication-strict.yaml" >/dev/null; sleep 5
for s in sidecar-lab ambient-lab; do
  printf '  legacy-lab -> httpbin.%s : ' "$s"
  kubectl exec -n legacy-lab deploy/curl -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://httpbin.$s:8000/get" 2>&1 | tail -1
done
