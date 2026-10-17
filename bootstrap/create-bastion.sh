#!/usr/bin/env bash
# =============================================================================
# Create the lab bastion.  RUN THIS IN AWS CLOUDSHELL (region us-east-1).
#
#   Amazon Linux 2023, t3.small, default VPC, NO inbound rules, NO SSH key.
#   Access = AWS Systems Manager Session Manager only.
#   Elastic IP = stable source IP for the EKS public-endpoint allow-list.
#
# Usage:   bash create-bastion.sh
# Env overrides:
#   AWS_REGION              (default us-east-1)
#   BASTION_NAME            (default istio-lab-bastion)
#   BASTION_INSTANCE_TYPE   (default t3.small)
#   BASTION_SUBNET_ID       (default: a default-VPC subnet)
#   BASTION_POLICY_ARN      (default AdministratorAccess - see WARNING)
#
# WARNING: the bastion runs Terraform that creates IAM roles/policies, EKS, VPC,
# ACM and Route 53 records. AdministratorAccess is the pragmatic choice for a
# DISPOSABLE lab account. Do not do this in a shared/production account.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
NAME="${BASTION_NAME:-istio-lab-bastion}"
ITYPE="${BASTION_INSTANCE_TYPE:-t3.small}"
POLICY_ARN="${BASTION_POLICY_ARN:-arn:aws:iam::aws:policy/AdministratorAccess}"
ROLE="${NAME}-role"
PROFILE="${NAME}-profile"
SG_NAME="${NAME}-sg"
export AWS_DEFAULT_REGION="$REGION"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

log "Identity"
aws sts get-caller-identity --output table

existing=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n "$existing" ]]; then
  echo "Bastion already exists: $existing  (connect: aws ssm start-session --target $existing)"
  exit 0
fi

# ---------------------------------------------------------------- network
if [[ -n "${BASTION_SUBNET_ID:-}" ]]; then
  SUBNET_ID="$BASTION_SUBNET_ID"
  VPC_ID=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId' --output text)
else
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && die "No default VPC in $REGION. Re-run with BASTION_SUBNET_ID=<public subnet id>."
  # Skip use1-az3 (old AZ; some instance types unavailable).
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query "Subnets[?AvailabilityZoneId!='use1-az3'] | [0].SubnetId" --output text)
fi
[[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] && die "Could not pick a subnet."
log "VPC=$VPC_ID  SUBNET=$SUBNET_ID"

# ---------------------------------------------------------------- IAM
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  log "Creating IAM role $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags Key=Project,Value=istio-gateway-lab >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN"

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1; then
  log "Creating instance profile $PROFILE"
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE"
  echo "Waiting 15s for IAM propagation..."; sleep 15
fi

# ---------------------------------------------------------------- security group
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  log "Creating security group $SG_NAME (no inbound rules)"
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
    --description "istio lab bastion - SSM only, no inbound" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=Project,Value=istio-gateway-lab}]" \
    --query GroupId --output text)
fi

# ---------------------------------------------------------------- instance
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
log "AMI=$AMI"

USERDATA=$(cat <<'EOF'
#!/bin/bash
dnf install -y git jq make tar gzip unzip gettext bind-utils openssl python3 tmux
hostnamectl set-hostname istio-lab-bastion
echo 'export AWS_DEFAULT_REGION=us-east-1' > /etc/profile.d/lab.sh
EOF
)

for attempt in 1 2 3 4 5; do
  if INSTANCE_ID=$(aws ec2 run-instances \
      --image-id "$AMI" --instance-type "$ITYPE" \
      --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
      --associate-public-ip-address \
      --iam-instance-profile Name="$PROFILE" \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2 \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
      --user-data "$USERDATA" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=Project,Value=istio-gateway-lab}]" \
      --query 'Instances[0].InstanceId' --output text 2>/tmp/run-instances.err); then
    break
  fi
  if grep -q "Invalid IAM Instance Profile" /tmp/run-instances.err; then
    echo "Instance profile not propagated yet (attempt $attempt) - retrying in 10s"; sleep 10
  else
    cat /tmp/run-instances.err; die "run-instances failed"
  fi
done
[[ -z "${INSTANCE_ID:-}" ]] && die "Could not launch instance"
log "Launched $INSTANCE_ID - waiting for running state"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# ---------------------------------------------------------------- Elastic IP
ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}},{Key=Project,Value=istio-gateway-lab}]" \
  --query AllocationId --output text)
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" >/dev/null
EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)

log "Waiting for SSM agent registration (up to ~3 min)"
for _ in $(seq 1 36); do
  ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
  [[ "$ping" == "Online" ]] && break
  sleep 5
done

cat <<EOF

=====================================================================
 Bastion ready
   Instance : $INSTANCE_ID
   Elastic IP: $EIP   (the EKS API will only accept this IP)
   SSM status: ${ping:-unknown}

 Connect (CloudShell):  aws ssm start-session --target $INSTANCE_ID
 Connect (Console):     EC2 > Instances > $NAME > Connect > Session Manager

 Then on the bastion:
   sudo su - ec2-user
   git clone https://github.com/<you>/eks-alb-istio-gateway-lab.git
   cd eks-alb-istio-gateway-lab && cp lab.env.example lab.env && vi lab.env
   make tools
=====================================================================
EOF
