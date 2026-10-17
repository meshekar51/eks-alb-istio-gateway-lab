#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "fix: use the us-east-1 cert from Terraform, then delete the stray cert"
kubectl annotate ingress edge-alb -n lab-gateway --overwrite "alb.ingress.kubernetes.io/certificate-arn=$ACM_CERT_ARN" >/dev/null
sleep 20
if [[ -f "$STATE_DIR/scenario02.cert" ]]; then
  aws acm delete-certificate --region eu-west-1 --certificate-arn "$(cat "$STATE_DIR/scenario02.cert")" && rm -f "$STATE_DIR/scenario02.cert"
fi
