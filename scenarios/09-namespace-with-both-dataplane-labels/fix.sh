#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
kubectl label ns ambient-lab istio-injection- >/dev/null
kubectl rollout restart deploy/httpbin deploy/curl -n ambient-lab >/dev/null
kubectl rollout status deploy/httpbin -n ambient-lab; kubectl rollout status deploy/curl -n ambient-lab
istioctl ztunnel-config workload | awk 'NR==1 || $1=="ambient-lab"'
