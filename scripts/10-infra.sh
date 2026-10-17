#!/usr/bin/env bash
# Terraform: VPC + EKS + nodes + add-ons + Pod Identity roles + ACM wildcard cert.
# ~15-20 minutes. Run from the bastion.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need terraform aws jq curl
load_env
export_tf_vars

log "Pre-flight"
run aws sts get-caller-identity --query Arn --output text
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${HOSTED_ZONE}." \
  --query "HostedZones[?Name=='${HOSTED_ZONE}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text)
[[ "$ZONE_ID" == "None" || -z "$ZONE_ID" ]] && die "No PUBLIC Route 53 zone named ${HOSTED_ZONE}. Create it / fix HOSTED_ZONE."
ok "Public hosted zone ${HOSTED_ZONE} -> ${ZONE_ID#/hostedzone/}"
NS=$(dig +short NS "${HOSTED_ZONE}" @1.1.1.1 | sort | head -1)
AWS_NS=$(aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers[0]' --output text)
if [[ -z "$NS" ]]; then
  warn "Public DNS returns no NS for ${HOSTED_ZONE}. Is the domain registered/delegated? ACM DNS validation will hang."
else
  ok "Public NS for ${HOSTED_ZONE}: $NS (zone's first NS: $AWS_NS)"
fi
ok "EKS API allow-list will be: ${TF_VAR_admin_cidrs:?}"

log "terraform init / plan / apply"
tf init -input=false -upgrade
tf plan -input=false -out="$STATE_DIR/tfplan"
if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Apply this plan? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "aborted"
fi
tf apply -input=false "$STATE_DIR/tfplan"
save_outputs

log "kubeconfig"
"$LAB_ROOT/scripts/kubeconfig.sh"

log "Nodes"
kubectl get nodes -o wide
ok "Infra ready. Next: make platform"
