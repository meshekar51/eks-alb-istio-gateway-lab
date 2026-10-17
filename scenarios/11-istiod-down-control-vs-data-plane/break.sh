#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "istiod scaled to 0"
kubectl scale deploy istiod -n istio-system --replicas=0 >/dev/null
kubectl wait --for=delete pod -n istio-system -l app=istiod --timeout=90s >/dev/null || true
echo "1) curl https://${SHOP_HOST}/api/info                 -> still works?"
echo "2) bash tools/canary.sh set 50 50                     -> does the split change?"
echo "3) kubectl rollout restart deploy/podinfo-v1 -n lab-apps ; kubectl get rs,pods -n lab-apps"
