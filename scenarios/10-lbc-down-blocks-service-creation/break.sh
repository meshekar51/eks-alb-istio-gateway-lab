#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "LBC scaled to 0 'to save money'"
kubectl scale deploy aws-load-balancer-controller -n kube-system --replicas=0 >/dev/null
kubectl wait --for=delete pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --timeout=90s >/dev/null || true
echo "Try:  kubectl create service clusterip scratch --tcp=80 -n lab-apps"
echo "and:  istioctl waypoint apply -n legacy-lab --name test-wp"
