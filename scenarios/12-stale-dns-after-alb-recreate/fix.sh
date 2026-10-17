#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
kubectl scale deploy external-dns -n external-dns --replicas=1
kubectl rollout status deploy/external-dns -n external-dns
echo "watch it reconcile:  kubectl logs -n external-dns deploy/external-dns -f | grep -i -E 'change|record'"
