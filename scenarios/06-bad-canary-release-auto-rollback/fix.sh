#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "fix: ship the good build again (re-apply the golden Deployment), then restart the canary at 90/10"
kapply "$LAB_ROOT/k8s/apps/podinfo.yaml"
kubectl rollout status deploy/podinfo-v2 -n lab-apps --timeout=3m
bash "$LAB_ROOT/tools/canary.sh" set 90 10
