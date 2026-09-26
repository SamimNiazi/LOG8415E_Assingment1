#!/bin/bash
# Step 3/4: 2 target groups + 1 ALB + path-based listener rules
set -e

TEAM_SEED=3165
STACK_NAME="assignment1-team-${TEAM_SEED}"

VPC_ID=$(cat vpc_id.txt)
SG_ID=$(cat sg_id.txt)
SUBNET_IDS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[].SubnetId' --output text)

echo "== Target groups =="
TG1_ARN=$(aws elbv2 create-target-group \
  --name "${STACK_NAME}-tg-small" --protocol HTTP --port 8000 --vpc-id "$VPC_ID" \
  --health-check-path /cluster1 --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

TG2_ARN=$(aws elbv2 create-target-group \
  --name "${STACK_NAME}-tg-large" --protocol HTTP --port 8000 --vpc-id "$VPC_ID" \
  --health-check-path /cluster2 --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

echo "== Registering targets =="
for id in $(cat small_instance_ids.txt); do
  aws elbv2 register-targets --target-group-arn "$TG1_ARN" --targets Id=$id
done
for id in $(cat large_instance_ids.txt); do
  aws elbv2 register-targets --target-group-arn "$TG2_ARN" --targets Id=$id
done

echo "== Application Load Balancer =="
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${STACK_NAME}-alb" --subnets $SUBNET_IDS --security-groups "$SG_ID" \
  --scheme internet-facing --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)

echo "== Listener + path-based rules =="
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG1_ARN \
  --query 'Listeners[0].ListenerArn' --output text)

aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 10 \
  --conditions Field=path-pattern,Values='/cluster1*' \
  --actions Type=forward,TargetGroupArn=$TG1_ARN

aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 20 \
  --conditions Field=path-pattern,Values='/cluster2*' \
  --actions Type=forward,TargetGroupArn=$TG2_ARN

echo "$ALB_ARN" > alb_arn.txt
echo "$ALB_DNS" > alb_dns.txt
echo "$TG1_ARN" > tg1_arn.txt
echo "$TG2_ARN" > tg2_arn.txt

echo "== Waiting for targets to pass health checks (can take ~1-2 min) =="
aws elbv2 wait target-in-service --target-group-arn "$TG1_ARN" || echo "cluster1 targets not all healthy yet, check manually"
aws elbv2 wait target-in-service --target-group-arn "$TG2_ARN" || echo "cluster2 targets not all healthy yet, check manually"

echo "ALB DNS: $ALB_DNS"
echo "Try:  curl http://$ALB_DNS/cluster1"
echo "      curl http://$ALB_DNS/cluster2"
