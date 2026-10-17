#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
kubectl annotate ingress edge-alb -n lab-gateway --overwrite alb.ingress.kubernetes.io/healthcheck-port=15021 >/dev/null
echo "fixed - targets become healthy after 2 intervals (~20s)"
