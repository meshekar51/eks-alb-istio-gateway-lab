#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
kubectl scale deploy istiod -n istio-system --replicas=1
kubectl rollout status deploy/istiod -n istio-system
kubectl rollout status deploy/podinfo-v1 -n lab-apps --timeout=5m || kubectl rollout restart deploy/podinfo-v1 -n lab-apps
istioctl proxy-status | head -20
