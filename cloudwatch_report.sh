#!/bin/bash
# Pulls CloudWatch metrics for both target groups (and the ALB) and dumps to CSV.
# Usage:
#   ./cloudwatch_report.sh                                  # last 2 hours (UTC)
#   ./cloudwatch_report.sh 2026-09-26T18:00:00 2026-09-26T18:30:00   # explicit window
#
# Run this right after your live demo slot with a window that covers the
# chaos check (Section 8) so the graphs are timestamped from the real thing,
# not a test run.
set -e

START_TIME=${1:-$(date -u -d '-2 hour' +%Y-%m-%dT%H:%M:%S)}
END_TIME=${2:-$(date -u +%Y-%m-%dT%H:%M:%S)}
PERIOD=60
OUT_DIR="cloudwatch_report_$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"

TG1_DIM=$(cat tg1_arn.txt | awk -F: '{print $NF}')
TG2_DIM=$(cat tg2_arn.txt | awk -F: '{print $NF}')
LB_DIM=$(cat alb_arn.txt | awk -F: '{print $NF}' | sed 's|loadbalancer/||')

echo "Time window: $START_TIME -> $END_TIME (UTC)"
echo "Output dir:  $OUT_DIR"
echo ""

fetch_metric() {
  local metric_name=$1
  local tg_label=$2
  local tg_dim=$3
  local stat=$4
  local out_file="$OUT_DIR/${metric_name}_${tg_label}.csv"

  {
    echo "timestamp,value"
    aws cloudwatch get-metric-statistics \
      --namespace AWS/ApplicationELB \
      --metric-name "$metric_name" \
      --dimensions Name=TargetGroup,Value="$tg_dim" Name=LoadBalancer,Value="$LB_DIM" \
      --start-time "$START_TIME" --end-time "$END_TIME" \
      --period "$PERIOD" --statistics "$stat" \
      --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,'"$stat"']' \
      --output text | tr '\t' ','
  } > "$out_file"

  local n=$(( $(wc -l < "$out_file") - 1 ))
  echo "  wrote $out_file ($n datapoints)"
}

for metric_stat in "HealthyHostCount:Average" "UnHealthyHostCount:Average" "RequestCount:Sum" "TargetResponseTime:Average"; do
  metric="${metric_stat%%:*}"
  stat="${metric_stat##*:}"
  echo "== $metric =="
  fetch_metric "$metric" "cluster1_small" "$TG1_DIM" "$stat"
  fetch_metric "$metric" "cluster2_large" "$TG2_DIM" "$stat"
done

echo ""
echo "Done. $OUT_DIR/ has 8 CSVs (4 metrics x 2 clusters)."
echo "For the chaos check, HealthyHostCount_*.csv is your key evidence: it should"
echo "dip by 1 at the moment the TA kills an instance, then recover if it respawns."
