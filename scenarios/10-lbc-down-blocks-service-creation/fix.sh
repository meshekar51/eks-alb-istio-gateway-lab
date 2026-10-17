#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
kubectl scale deploy aws-load-balancer-controller -n kube-system --replicas=2
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system
kubectl delete svc scratch -n lab-apps --ignore-not-found; istioctl waypoint delete test-wp -n legacy-lab 2>/dev/null || true
