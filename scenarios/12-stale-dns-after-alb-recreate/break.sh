#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "ExternalDNS paused, then the ALB is re-created (new DNS name)"
kubectl scale deploy external-dns -n external-dns --replicas=0 >/dev/null
OLD=$(alb_hostname); echo "old ALB: $OLD"
kubectl delete ingress edge-alb -n lab-gateway --wait=true >/dev/null
kapply "$LAB_ROOT/k8s/ingress" >/dev/null
for _ in $(seq 1 60); do NEW=$(alb_hostname); [[ -n "$NEW" ]] && break; sleep 5; done
echo "new ALB: $NEW"
echo "Now compare: dig +short ${SHOP_HOST}   vs   dig +short $NEW"
