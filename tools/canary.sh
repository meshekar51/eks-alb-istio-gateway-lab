#!/usr/bin/env bash
# Canary control for shop.<DOMAIN> (the `weighted` rule of HTTPRoute lab-apps/shop).
#
#   tools/canary.sh status            show weights + sample 100 requests
#   tools/canary.sh set 75 25         set podinfo-v1=75 podinfo-v2=25 (re-renders k8s/routes/shop.yaml)
#   tools/canary.sh rollout           progressive 90/10 -> 75/25 -> 50/50 -> 25/75 -> 0/100,
#                                     sampling after each step; auto-ROLLBACK to 100/0 on errors
#   tools/canary.sh rollback          100/0 immediately
#
# Weights are relative (90/10 == 9/1). Keep BOTH backendRefs during a rollout so rollback is
# a one-line change. Never mix this with an Istio VirtualService for the same host.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
load_env
kctx_check

apply_weights() {
  export CANARY_V1_WEIGHT="$1" CANARY_V2_WEIGHT="$2"
  kapply "$LAB_ROOT/k8s/routes/shop.yaml" >/dev/null
  echo "export CANARY_V1_WEIGHT=$1 CANARY_V2_WEIGHT=$2" > "$STATE_DIR/canary.env"
  ok "weights now v1=$1 v2=$2  (generation $(kubectl get httproute shop -n lab-apps -o jsonpath='{.metadata.generation}'))"
  sleep 3   # istiod -> gateway push is usually < 1s; give it a moment
}

sample() { N="${1:-100}" bash "$LAB_ROOT/tests/30-canary.sh"; }

case "${1:-status}" in
  status)   sample 100 ;;
  set)      [[ $# -eq 3 ]] || die "usage: $0 set <v1> <v2>"; apply_weights "$2" "$3"; sample 100 ;;
  rollback) apply_weights 100 0; sample 50 ;;
  rollout)
    for step in "90 10" "75 25" "50 50" "25 75" "0 100"; do
      read -r a b <<<"$step"
      log "Step: v1=$a v2=$b"
      apply_weights "$a" "$b"
      if ! sample 200; then
        bad "canary analysis FAILED at v1=$a v2=$b -> rolling back"
        apply_weights 100 0
        exit 1
      fi
      [[ "${PAUSE:-1}" == "1" ]] && read -r -p "  promote further? [Enter = yes, Ctrl-C = stop] " _
    done
    ok "v2 fully promoted. Next real-world step: make v2 the new 'stable' Deployment and remove v1."
    ;;
  *) die "usage: $0 status|set <v1> <v2>|rollout|rollback" ;;
esac
