#!/bin/bash
# Step 1/4: provision 5x t3.micro (cluster1) + 4x m7g.large (cluster2, Graviton)
# Falls back to m6i.large if m7g.large isn't offered in this region.
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

echo "== Launching 5x t3.micro (cluster1 / small) =="
SMALL_IDS=$(aws ec2 run-instances \
  --image-id "$AMI_X86" --instance-type t3.micro --count 5 \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-small},{Key=Cluster,Value=cluster1}]" \
  --query 'Instances[].InstanceId' --output text)
echo "$SMALL_IDS" | tr '\t' '\n' > small_instance_ids.txt

echo "== Launching 4x m7g.large (cluster2 / large) =="
if ! LARGE_IDS=$(aws ec2 run-instances \
  --image-id "$AMI_ARM" --instance-type m7g.large --count 4 \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-large},{Key=Cluster,Value=cluster2}]" \
  --query 'Instances[].InstanceId' --output text 2>/dev/null); then
  echo "m7g.large unavailable in this region, falling back to m6i.large (x86)"
  LARGE_IDS=$(aws ec2 run-instances \
    --image-id "$AMI_X86" --instance-type m6i.large --count 4 \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-large},{Key=Cluster,Value=cluster2}]" \
    --query 'Instances[].InstanceId' --output text)
fi
echo "$LARGE_IDS" | tr '\t' '\n' > large_instance_ids.txt

echo "== Waiting for instances to reach running state =="
aws ec2 wait instance-running --instance-ids $(cat small_instance_ids.txt) $(cat large_instance_ids.txt)

echo "Provisioning complete."
echo "Small (cluster1): $(cat small_instance_ids.txt | tr '\n' ' ')"
echo "Large (cluster2): $(cat large_instance_ids.txt | tr '\n' ' ')"
