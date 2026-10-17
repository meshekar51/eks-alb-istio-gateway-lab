#!/usr/bin/env bash
# Delete the bastion and everything create-bastion.sh made. RUN IN CLOUDSHELL,
# and only AFTER `make destroy` finished on the bastion (local Terraform state lives there!).
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
NAME="${BASTION_NAME:-istio-lab-bastion}"
POLICY_ARN="${BASTION_POLICY_ARN:-arn:aws:iam::aws:policy/AdministratorAccess}"
ROLE="${NAME}-role"; PROFILE="${NAME}-profile"; SG_NAME="${NAME}-sg"
export AWS_DEFAULT_REGION="$REGION"

# Safety net: refuse while the lab cluster still exists (its state is on the bastion).
if aws eks describe-cluster --name "${CLUSTER_NAME:-istio-gateway-lab}" >/dev/null 2>&1; then
  echo "EKS cluster ${CLUSTER_NAME:-istio-gateway-lab} still exists. Run 'make destroy' on the bastion first."
  echo "Override with FORCE=1 if you really mean it."
  [[ "${FORCE:-0}" == "1" ]] || exit 1
fi

read -r -p "Type DELETE to remove bastion ${NAME}: " ans; [[ "$ans" == "DELETE" ]] || exit 1

IDS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${NAME}" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

for id in $IDS; do
  for alloc in $(aws ec2 describe-addresses --filters "Name=instance-id,Values=${id}" --query 'Addresses[].AllocationId' --output text); do
    assoc=$(aws ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].AssociationId' --output text)
    [[ "$assoc" != "None" ]] && aws ec2 disassociate-address --association-id "$assoc"
    aws ec2 release-address --allocation-id "$alloc" && echo "Released EIP $alloc"
  done
done
# Also release any EIP left tagged with the bastion name.
for alloc in $(aws ec2 describe-addresses --filters "Name=tag:Name,Values=${NAME}" --query 'Addresses[].AllocationId' --output text); do
  aws ec2 release-address --allocation-id "$alloc" 2>/dev/null && echo "Released EIP $alloc" || true
done

if [[ -n "$IDS" ]]; then
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  echo "Terminating $IDS ..."; aws ec2 wait instance-terminated --instance-ids $IDS
fi

SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query 'SecurityGroups[0].GroupId' --output text)
[[ "$SG_ID" != "None" && -n "$SG_ID" ]] && aws ec2 delete-security-group --group-id "$SG_ID" && echo "Deleted $SG_ID"

if aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE"
fi
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || true
  aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" || true
  aws iam delete-role --role-name "$ROLE"
fi
echo "Bastion removed."
