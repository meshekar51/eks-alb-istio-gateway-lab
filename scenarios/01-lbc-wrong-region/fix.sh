#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "fix: pin region AND vpc explicitly, then prove it from the Deployment args"
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --version "$LBC_CHART_VERSION" --reuse-values --set region="$AWS_REGION" --set vpcId="$VPC_ID" --wait >/dev/null
kubectl get deploy aws-load-balancer-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E 'region|vpc'
kubectl annotate ingress edge-alb -n lab-gateway lab.io/poke- >/dev/null 2>&1 || true
