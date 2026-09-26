#!/bin/bash
# Step 1/4: provision 5x small (cluster1) + 4x large (cluster2)
# Idempotent: skips creation if matching running/pending instances already exist.
# Tries a chain of instance types in case your Learner Lab restricts newer families.
set -e

TEAM_SEED=3165
STACK_NAME="assignment1-team-${TEAM_SEED}"
KEY_NAME="${STACK_NAME}-key"
SG_NAME="${STACK_NAME}-sg"

echo "== Key pair =="
if [ ! -f "${KEY_NAME}.pem" ]; then
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
fi

echo "== Default VPC / subnet =="
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[0].SubnetId' --output text)
echo "$VPC_ID" > vpc_id.txt
echo "$SUBNET_ID" > subnet_id.txt

echo "== Security group =="
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAME Name=vpc-id,Values=$VPC_ID \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "SG for $STACK_NAME" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 9000 --cidr 0.0.0.0/0
fi
echo "$SG_ID" > sg_id.txt

echo "== AMI lookup =="
AMI_X86=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
AMI_ARM=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query 'Parameters[0].Value' --output text)

# --- reuse existing instances if this script already ran successfully ---
existing_ids() {
  local name_tag=$1
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${name_tag}" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

echo "== Cluster1 (small, t3.micro) =="
EXISTING_SMALL=$(existing_ids "${STACK_NAME}-small")
if [ -n "$EXISTING_SMALL" ]; then
  echo "Found existing running/pending small instances, reusing: $EXISTING_SMALL"
  echo "$EXISTING_SMALL" | tr '\t' '\n' > small_instance_ids.txt
else
  SMALL_IDS=$(aws ec2 run-instances \
    --image-id "$AMI_X86" --instance-type t3.micro --count 5 \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-small},{Key=Cluster,Value=cluster1}]" \
    --query 'Instances[].InstanceId' --output text)
  echo "$SMALL_IDS" | tr '\t' '\n' > small_instance_ids.txt
fi

echo "== Cluster2 (large) =="
EXISTING_LARGE=$(existing_ids "${STACK_NAME}-large")
if [ -n "$EXISTING_LARGE" ]; then
  echo "Found existing running/pending large instances, reusing: $EXISTING_LARGE"
  echo "$EXISTING_LARGE" | tr '\t' '\n' > large_instance_ids.txt
else
  # Try instance types in order until one actually launches AND survives past pending.
  # Learner Labs commonly restrict newer/graviton families, so fall all the way
  # back to a type we already know is allowed (t3.large) if needed.
  LARGE_TYPES=(m7g.large c7g.large m6i.large c6i.large m5.large t3.large)
  LARGE_AMI_FOR_TYPE() { case "$1" in m7g.large|c7g.large) echo "$AMI_ARM" ;; *) echo "$AMI_X86" ;; esac; }

  LARGE_IDS=""
  for t in "${LARGE_TYPES[@]}"; do
    ami=$(LARGE_AMI_FOR_TYPE "$t")
    echo "Trying instance type: $t"
    if ids=$(aws ec2 run-instances \
        --image-id "$ami" --instance-type "$t" --count 4 \
        --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
        --associate-public-ip-address \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-large},{Key=Cluster,Value=cluster2}]" \
        --query 'Instances[].InstanceId' --output text 2>launch_err.log); then
      # launch call succeeded — but Learner Lab compliance can still kill it
      # seconds later, so verify it's still alive before trusting it.
      sleep 15
      alive=$(aws ec2 describe-instances --instance-ids $ids \
        --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text)
      if echo "$alive" | grep -qv "terminated\|shutting-down"; then
        echo "$t launched and is still alive:"
        echo "$alive"
        LARGE_IDS="$ids"
        echo "$t" > large_instance_type.txt
        break
      else
        echo "$t was auto-terminated shortly after launch (Learner Lab restriction). Trying next type."
        echo "$alive"
      fi
    else
      echo "$t rejected at launch:"
      cat launch_err.log
      echo "Trying next type."
    fi
  done

  if [ -z "$LARGE_IDS" ]; then
    echo "ERROR: none of the candidate large instance types survived in this Learner Lab."
    echo "Check the region restriction panel in your lab page and adjust LARGE_TYPES in this script."
    exit 1
  fi
  echo "$LARGE_IDS" | tr '\t' '\n' > large_instance_ids.txt
fi

echo "== Waiting for instances to reach running state =="
ALL_IDS="$(cat small_instance_ids.txt) $(cat large_instance_ids.txt)"
if ! aws ec2 wait instance-running --instance-ids $ALL_IDS; then
  echo "Waiter failed. Current states:"
  aws ec2 describe-instances --instance-ids $ALL_IDS \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,StateTransitionReason]' \
    --output table
  exit 1
fi

echo "Provisioning complete."
echo "Small (cluster1): $(cat small_instance_ids.txt | tr '\n' ' ')"
echo "Large (cluster2), type $(cat large_instance_type.txt 2>/dev/null || echo '?'): $(cat large_instance_ids.txt | tr '\n' ' ')"