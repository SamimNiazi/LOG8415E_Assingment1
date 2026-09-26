#!/bin/bash
# Single-command entry point for the demo (Section 7).
# Team seed 3165 -> failover threshold 215 ms.
set -e

echo "########## 1/5 Provisioning EC2 instances ##########"
bash provision.sh

echo "########## 2/5 Deploying FastAPI app to all 9 instances ##########"
bash deploy_app.sh

echo "########## 3/5 Setting up the ALB, target groups, routing rules ##########"
bash setup_alb.sh

echo "########## 4/5 Starting the custom load balancer (port 9000) ##########"
python3 -m venv lb_venv
source lb_venv/bin/activate
pip install -q fastapi "uvicorn[standard]" httpx aiohttp
nohup python3 custom_lb.py > custom_lb.log 2>&1 &
echo $! > custom_lb.pid
sleep 5
echo "Custom LB started, PID $(cat custom_lb.pid). Logs: custom_lb.log"

echo "########## 5/5 Running benchmarks ##########"
ALB_DNS=$(cat alb_dns.txt)

echo "--- AWS ALB /cluster1 ---"
python3 benchmark.py "http://$ALB_DNS" /cluster1
echo "--- AWS ALB /cluster2 ---"
python3 benchmark.py "http://$ALB_DNS" /cluster2
echo "--- Custom LB /cluster1 ---"
python3 benchmark.py "http://localhost:9000" /cluster1
echo "--- Custom LB /cluster2 ---"
python3 benchmark.py "http://localhost:9000" /cluster2

echo ""
echo "All done. For the chaos check, watch: tail -f custom_lb.log"
echo "and: watch -n1 curl -s http://localhost:9000/lb-status"
