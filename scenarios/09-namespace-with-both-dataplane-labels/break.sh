#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "someone also turns on sidecar injection in ambient-lab"
echo "BEFORE:"; istioctl ztunnel-config workload | awk 'NR==1 || $1=="ambient-lab"'
kubectl label ns ambient-lab istio-injection=enabled --overwrite >/dev/null
kubectl rollout restart deploy/httpbin deploy/curl -n ambient-lab >/dev/null
kubectl rollout status deploy/httpbin -n ambient-lab >/dev/null; kubectl rollout status deploy/curl -n ambient-lab >/dev/null
echo "AFTER:"; kubectl get pods -n ambient-lab -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name,INIT:.spec.initContainers[*].name'
istioctl ztunnel-config workload | awk 'NR==1 || $1=="ambient-lab"'
