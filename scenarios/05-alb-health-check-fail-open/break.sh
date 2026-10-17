#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "health check moved to port 8080 (nothing listens there)"
kubectl annotate ingress edge-alb -n lab-gateway --overwrite alb.ingress.kubernetes.io/healthcheck-port=8080 >/dev/null
echo "Broken. Wait ~60s, then: bash tests/10-edge.sh  AND  curl https://${SHOP_HOST}/api/info"
