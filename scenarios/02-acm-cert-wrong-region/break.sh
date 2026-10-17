#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
OTHER=eu-west-1
banner "listener certificate lives in ${OTHER}, the ALB in ${AWS_REGION}"
T=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 7 -keyout "$T/k" -out "$T/c" -subj "/CN=*.${DOMAIN}" \
  -addext "subjectAltName=DNS:*.${DOMAIN}" 2>/dev/null
ARN=$(aws acm import-certificate --region "$OTHER" --certificate "fileb://$T/c" --private-key "fileb://$T/k" \
  --tags Key=Lab,Value=messy Key=Project,Value="$CLUSTER_NAME" --query CertificateArn --output text)
rm -rf "$T"; echo "$ARN" > "$STATE_DIR/scenario02.cert"
kubectl annotate ingress edge-alb -n lab-gateway --overwrite "alb.ingress.kubernetes.io/certificate-arn=$ARN" >/dev/null
echo "Broken. Look at the Ingress events and the LBC log."
