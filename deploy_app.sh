#!/bin/bash
# Step 2/4: copy main.py to every instance, install deps, run under systemd
set -e

KEY_FILE="assignment1-team-3165-key.pem"
SSH_USER="ec2-user"

> small_ips.txt
> large_ips.txt

deploy_one() {
  local ip=$1
  local instance_num=$2
  local route=$3

  echo ">> $ip  (instance_id=$instance_num, route=$route)"

  for i in $(seq 1 20); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY_FILE" $SSH_USER@$ip "echo ok" 2>/dev/null; then
      break
    fi
    sleep 10
  done

  scp -o StrictHostKeyChecking=no -i "$KEY_FILE" main.py $SSH_USER@$ip:/home/$SSH_USER/main.py

  ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" $SSH_USER@$ip bash -s -- "$instance_num" "$route" << 'REMOTE'
set -e
INSTANCE_NUM="$1"
ROUTE="$2"

sudo dnf update -y -q
sudo dnf install -y -q python3 python3-pip
python3 -m venv /home/ec2-user/.venv
source /home/ec2-user/.venv/bin/activate
pip install -q fastapi "uvicorn[standard]"

sudo tee /etc/systemd/system/fastapi-app.service > /dev/null << UNIT
[Unit]
Description=FastAPI benchmarking app
After=network.target

[Service]
Environment=INSTANCE_ID=${INSTANCE_NUM}
Environment=CLUSTER_ROUTE=${ROUTE}
ExecStart=/home/ec2-user/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
WorkingDirectory=/home/ec2-user
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable fastapi-app
sudo systemctl restart fastapi-app
REMOTE
}

echo "== Deploying to small cluster (/cluster1) =="
n=1
for id in $(cat small_instance_ids.txt); do
  ip=$(aws ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "$ip" >> small_ips.txt
  deploy_one "$ip" "$n" "/cluster1"
  n=$((n+1))
done

echo "== Deploying to large cluster (/cluster2) =="
n=1
for id in $(cat large_instance_ids.txt); do
  ip=$(aws ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "$ip" >> large_ips.txt
  deploy_one "$ip" "$n" "/cluster2"
  n=$((n+1))
done

echo "Done. IPs saved to small_ips.txt / large_ips.txt"
