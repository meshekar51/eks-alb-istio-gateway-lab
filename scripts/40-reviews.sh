#!/usr/bin/env bash
# OPTIONAL add-on: the "reviews" topology
#   User → ALB → Istio Gateway pod → HTTPRoute (90/10) → reviews-v1 / reviews-v2 Service → Pod
#
#   bash scripts/40-reviews.sh            deploy (weights from lab.env, default 90/10) + sample
#   bash scripts/40-reviews.sh 50 50      change the split + sample
#   bash scripts/40-reviews.sh sample     sample only
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl curl jq
load_env
require_outputs
kctx_check
HOST="reviews.${DOMAIN}"
F="$LAB_ROOT/k8s/addons/reviews/reviews.yaml"

if [[ "${1:-}" != "sample" ]]; then
  if [[ $# -eq 2 ]]; then export REVIEWS_V1_WEIGHT="$1" REVIEWS_V2_WEIGHT="$2"; fi
  log "Deploy reviews add-on (v1=${REVIEWS_V1_WEIGHT} v2=${REVIEWS_V2_WEIGHT})"
  kapply "$F"
  for d in reviews-v1 reviews-v2 ratings-v1; do kubectl rollout status "deploy/$d" -n bookinfo --timeout=5m; done
  sleep 3
  kubectl get httproute reviews -n bookinfo -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}' | sed 's/^/  /'
fi

ALB=$(alb_hostname)
CT=()
getent hosts "$HOST" >/dev/null 2>&1 || { CT=(--connect-to "${HOST}:443:${ALB}:443"); warn "$HOST not resolvable yet - connecting straight to the ALB"; }

log "Sample 100 requests: https://${HOST}/reviews/0"
v1=0; v2=0; other=0
for _ in $(seq 1 100); do
  pod=$(curl -s --max-time 10 "${CT[@]}" "https://${HOST}/reviews/0" | jq -r '.podname // "error"' 2>/dev/null || echo error)
  case "$pod" in reviews-v1-*) v1=$((v1+1));; reviews-v2-*) v2=$((v2+1));; *) other=$((other+1));; esac
done
printf '  reviews-v1 %3d  %s\n  reviews-v2 %3d  %s\n  errors     %3d\n' \
  "$v1" "$(printf '%*s' $((v1/2)) '' | tr ' ' '#')" "$v2" "$(printf '%*s' $((v2/2)) '' | tr ' ' '#')" "$other"

log "Header rule from your istio-guide (end-user: jason -> v2)"
for _ in 1 2 3; do
  curl -s --max-time 10 "${CT[@]}" -H 'end-user: jason' "https://${HOST}/reviews/0" | jq -r '"  " + .podname'
done
echo
echo "  Browser: https://${HOST}/reviews/0   (JSON; podname shows the version)"
echo "  Shift:   bash scripts/40-reviews.sh 50 50    |    remove: kubectl delete ns bookinfo"
