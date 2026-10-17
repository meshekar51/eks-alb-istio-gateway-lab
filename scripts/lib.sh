#!/usr/bin/env bash
# Shared helpers. Source me:  source "$(dirname "$0")/../scripts/lib.sh"
# shellcheck disable=SC2034

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$LAB_ROOT/.state"
RENDER_DIR="$LAB_ROOT/.rendered"
TF_DIR="$LAB_ROOT/infra/terraform"
mkdir -p "$STATE_DIR" "$RENDER_DIR"

if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_CYN=$'\033[1;36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""; C_OFF=""
fi

log()  { printf '\n%s==> %s%s\n' "$C_CYN" "$*" "$C_OFF"; }
ok()   { printf '  %s✔%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
run()  { printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_OFF"; "$@"; }

need() {
  local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing tool: $c (run: make tools)"; done
}

load_env() {
  [[ -f "$LAB_ROOT/lab.env" ]] || die "lab.env not found. cp lab.env.example lab.env && edit DOMAIN/HOSTED_ZONE"
  # shellcheck source=/dev/null
  source "$LAB_ROOT/lab.env"
  [[ "${DOMAIN:-}" == "lab.example.com" || -z "${DOMAIN:-}" ]] && die "Set DOMAIN in lab.env to a sub-domain you own."
  [[ "${HOSTED_ZONE:-}" == "example.com" || -z "${HOSTED_ZONE:-}" ]] && die "Set HOSTED_ZONE in lab.env."
  export AWS_DEFAULT_REGION="$AWS_REGION"
  # Hostnames used everywhere
  export SHOP_HOST="shop.${DOMAIN}" API_HOST="api.${DOMAIN}" CANARY_HOST="canary.${DOMAIN}"
  # outputs from terraform (if already applied)
  # shellcheck source=/dev/null
  [[ -f "$STATE_DIR/outputs.env" ]] && source "$STATE_DIR/outputs.env"
  # current canary weights (written by tools/canary.sh) survive re-deploys
  # shellcheck source=/dev/null
  [[ -f "$STATE_DIR/canary.env" ]] && source "$STATE_DIR/canary.env"
  return 0
}

tf() { terraform -chdir="$TF_DIR" "$@"; }

# Export TF_VAR_* from lab.env (lab.env stays the single source of truth).
export_tf_vars() {
  export TF_VAR_region="$AWS_REGION"
  export TF_VAR_cluster_name="$CLUSTER_NAME"
  export TF_VAR_kubernetes_version="$K8S_VERSION"
  export TF_VAR_domain="$DOMAIN"
  export TF_VAR_hosted_zone="$HOSTED_ZONE"
  local ip
  ip="${ADMIN_CIDR_OVERRIDE:-$(curl -4fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
  [[ "$ip" == "/32" ]] && die "Could not detect this host's public IP (checkip.amazonaws.com)."
  export TF_VAR_admin_cidrs="[\"${ip}\"]"
  local arns="[]"
  if [[ -n "${ADMIN_PRINCIPAL_ARNS:-}" ]]; then
    arns=$(printf '%s' "$ADMIN_PRINCIPAL_ARNS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
  fi
  export TF_VAR_admin_principal_arns="$arns"
}

# Cache terraform outputs as shell variables in .state/outputs.env
save_outputs() {
  tf output -json > "$STATE_DIR/outputs.json"
  jq -r '
    "export VPC_ID=\(.vpc_id.value)",
    "export ACM_CERT_ARN=\(.acm_certificate_arn.value)",
    "export HOSTED_ZONE_ID=\(.hosted_zone_id.value)",
    "export PUBLIC_SUBNET_IDS=\"\(.public_subnet_ids.value | join(" "))\"",
    "export PRIVATE_SUBNET_IDS=\"\(.private_subnet_ids.value | join(" "))\"",
    "export CLUSTER_SG_ID=\(.cluster_security_group_id.value)",
    "export LBC_ROLE_ARN=\(.lbc_role_arn.value)",
    "export EXTERNAL_DNS_ROLE_ARN=\(.external_dns_role_arn.value)",
    "export NODE_ROLE_ARN=\(.node_role_arn.value)"
  ' "$STATE_DIR/outputs.json" > "$STATE_DIR/outputs.env"
  # shellcheck source=/dev/null
  source "$STATE_DIR/outputs.env"
}

require_outputs() {
  [[ -n "${VPC_ID:-}" && -n "${ACM_CERT_ARN:-}" ]] || die "Terraform outputs missing. Run: make infra"
}

# Only these variables are substituted, so '$' elsewhere in YAML is untouched.
RENDER_VARS='${DOMAIN} ${HOSTED_ZONE} ${HOSTED_ZONE_ID} ${AWS_REGION} ${CLUSTER_NAME} ${VPC_ID} ${ACM_CERT_ARN} ${SHOP_HOST} ${API_HOST} ${CANARY_HOST} ${PODINFO_V1_IMAGE} ${PODINFO_V2_IMAGE} ${HTTPBIN_IMAGE} ${CURL_IMAGE} ${CANARY_V1_WEIGHT} ${CANARY_V2_WEIGHT} ${REVIEWS_V1_IMAGE} ${REVIEWS_V2_IMAGE} ${RATINGS_IMAGE} ${REVIEWS_V1_WEIGHT} ${REVIEWS_V2_WEIGHT}'

# render <src> -> prints path of rendered file
render() {
  local src="$1" rel out
  rel="${src#"$LAB_ROOT"/}"
  out="$RENDER_DIR/$rel"
  mkdir -p "$(dirname "$out")"
  envsubst "$RENDER_VARS" < "$src" > "$out"
  if grep -n '\${[A-Z_]*}' "$out" >/dev/null; then
    die "unrendered variable in $out: $(grep -o '\${[A-Z_]*}' "$out" | sort -u | tr '\n' ' ')"
  fi
  printf '%s\n' "$out"
}

# kapply <file|dir> [extra kubectl args]  - renders then applies
kapply() {
  local target="$1"; shift || true
  local f
  if [[ -d "$target" ]]; then
    while IFS= read -r f; do kapply "$f" "$@"; done < <(find "$target" -maxdepth 1 -name '*.yaml' | sort)
    return
  fi
  f=$(render "$target")
  run kubectl apply -f "$f" "$@"
}

kctx_check() {
  kubectl version --request-timeout=10s >/dev/null 2>&1 || die "kubectl cannot reach the cluster. Run: make kubeconfig (and check the API allow-list IP)"
}

alb_hostname() {
  kubectl get ingress edge-alb -n lab-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}
