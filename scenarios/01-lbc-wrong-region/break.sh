#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "LBC told to work in ap-southeast-2 (the cluster is in ${AWS_REGION})"
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --version "$LBC_CHART_VERSION" --reuse-values --set region=ap-southeast-2 >/dev/null   # no --wait: pods may not even become Ready
# force a reconcile so the error shows up now
kubectl annotate ingress edge-alb -n lab-gateway lab.io/poke="$(date +%s)" --overwrite >/dev/null
echo "Broken. Symptom hunt: kubectl describe ingress edge-alb -n lab-gateway ; LBC logs"
