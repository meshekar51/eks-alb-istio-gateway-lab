#!/usr/bin/env bash
# Tear down in the ONLY order that leaves nothing behind:
#   1. delete the Ingress  -> LBC deletes ALB, target group, its security groups
#                          -> ExternalDNS (policy=sync) deletes the Route 53 records
#   2. delete waypoint/gateways, then Helm releases (controllers must outlive their objects!)
#   3. clean leftovers that block VPC deletion (LBC security groups, messy-lab ACM imports)
#   4. terraform destroy
# Skipping step 1 is the #1 cause of "DependencyViolation" on VPC/subnet delete.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
load_env
export_tf_vars
LB_NAME="${CLUSTER_NAME}-edge"

if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Destroy EVERYTHING in cluster ${CLUSTER_NAME} (${AWS_REGION})? type DESTROY: " a
  [[ "$a" == "DESTROY" ]] || die "aborted"
fi

if kubectl version --request-timeout=10s >/dev/null 2>&1; then
  log "1. Ingress -> ALB + DNS records"
  kubectl delete ingress edge-alb -n lab-gateway --ignore-not-found --wait=true --timeout=5m
  for _ in $(seq 1 30); do
    aws elbv2 describe-load-balancers --names "$LB_NAME" >/dev/null 2>&1 || { ok "ALB $LB_NAME gone"; break; }
    sleep 10
  done
  echo "  giving ExternalDNS 90s to delete Route 53 records..."
  sleep 90
  left=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "length(ResourceRecordSets[?ends_with(Name, '${DOMAIN}.') && (Type=='A' || Type=='TXT') && !starts_with(Name, '_')])" --output text 2>/dev/null)
  [[ "${left:-0}" == "0" ]] && ok "no lab A/TXT records left" || warn "$left lab record(s) still in the zone (check: make doctor / Route 53 console)"

  log "2. Gateways, workloads, controllers"
  kubectl delete gateway --all -n ambient-lab --ignore-not-found --wait=true
  kubectl delete gateway --all -n lab-gateway --ignore-not-found --wait=true
  kubectl delete ns bookinfo sidecar-lab ambient-lab legacy-lab lab-apps lab-gateway --ignore-not-found --wait=true --timeout=5m
  helm uninstall external-dns -n external-dns 2>/dev/null || true
  istioctl uninstall --purge -y 2>/dev/null || true
  helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
else
  warn "cluster unreachable - skipping Kubernetes cleanup (check leftovers manually afterwards)"
fi

log "3. Leftovers that block VPC deletion"
if [[ -n "${VPC_ID:-}" ]]; then
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" --query 'SecurityGroups[].GroupId' --output text); do
    aws ec2 delete-security-group --group-id "$sg" && ok "deleted LBC security group $sg" || warn "could not delete $sg yet"
  done
  for lb in $(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text); do
    warn "load balancer still in VPC: $lb - deleting"; aws elbv2 delete-load-balancer --load-balancer-arn "$lb"
  done
fi
for arn in $(aws acm list-certificates --query 'CertificateSummaryList[].CertificateArn' --output text); do
  if aws acm list-tags-for-certificate --certificate-arn "$arn" --query 'Tags[?Key==`Lab`].Value' --output text 2>/dev/null | grep -q messy; then
    aws acm delete-certificate --certificate-arn "$arn" && ok "deleted messy-lab imported cert $arn" || warn "imported cert $arn still in use"
  fi
done

log "4. terraform destroy"
tf init -input=false >/dev/null
tf destroy -input=false -auto-approve   # you already typed DESTROY above

log "Final check (should all be empty)"
aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 && bad "cluster still exists" || ok "cluster gone"
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=${CLUSTER_NAME}" --query 'Vpcs[].VpcId' --output text
aws ec2 describe-nat-gateways --filter "Name=tag:Project,Values=${CLUSTER_NAME}" "Name=state,Values=available,pending" --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --filters "Name=tag:Project,Values=${CLUSTER_NAME}" --query 'Addresses[].PublicIp' --output text
rm -f "$STATE_DIR/outputs.env" "$STATE_DIR/canary.env"
ok "Lab destroyed. The bastion is separate: run bootstrap/delete-bastion.sh from CloudShell if you are done."
