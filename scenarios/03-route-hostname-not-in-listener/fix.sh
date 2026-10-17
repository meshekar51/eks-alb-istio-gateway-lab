#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "fix: a hostname inside the listener's *.${DOMAIN}"
kubectl patch httproute promo -n lab-apps --type=merge -p "{\"spec\":{\"hostnames\":[\"promo.${DOMAIN}\"]}}"
kubectl get httproute promo -n lab-apps -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")]}'; echo
echo "Now: curl --connect-to promo.${DOMAIN}:443:<ALB>:443 https://promo.${DOMAIN}/   (cleanup: kubectl delete httproute promo -n lab-apps)"
