#!/bin/bash
# Tears down everything tagged with this team's stack name.
# Run this between debugging attempts so orphaned instances don't eat your $50 budget.
set -e

TEAM_SEED=3165
STACK_NAME="assignment1-team-${TEAM_SEED}"

echo "== Terminating EC2 instances =="
IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${STACK_NAME}-small,${STACK_NAME}-large" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS
  echo "Terminating: $IDS"
else
  echo "No instances found."
fi

echo "== Deleting load balancer (if any) =="
if [ -f alb_arn.txt ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$(cat alb_arn.txt)" || true
fi

echo "== Deleting target groups (after ALB is gone, wait a moment) =="
sleep 10
[ -f tg1_arn.txt ] && aws elbv2 delete-target-group --target-group-arn "$(cat tg1_arn.txt)" || true
[ -f tg2_arn.txt ] && aws elbv2 delete-target-group --target-group-arn "$(cat tg2_arn.txt)" || true

echo "== Stopping local custom load balancer if running =="
if [ -f custom_lb.pid ]; then
  kill "$(cat custom_lb.pid)" 2>/dev/null || true
  rm -f custom_lb.pid
fi

echo "== Cleaning up local state files =="
rm -f small_instance_ids.txt large_instance_ids.txt small_ips.txt large_ips.txt \
      alb_arn.txt alb_dns.txt tg1_arn.txt tg2_arn.txt large_instance_type.txt launch_err.log

echo "Done. Security group and key pair were left in place (cheap to keep, reused on next run)."
echo "Run 'aws ec2 describe-instances --filters Name=tag:Name,Values=${STACK_NAME}-*' to confirm nothing's left running."
