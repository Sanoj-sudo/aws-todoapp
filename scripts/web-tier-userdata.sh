#!/bin/bash
# EC2 user-data for the WEB tier (Amazon Linux 2023, public subnet / behind public ALB).
# Requirements:
#   - Instance profile (IAM role) with s3:GetObject / s3:ListBucket on S3_BUCKET
#   - Security group: allow 80 from the public ALB security group
set -euxo pipefail

# ======== EDIT THESE ========
S3_BUCKET="my-three-tier-app-bucket"
BACKEND_URL="http://internal-app-alb-xxxxxxxx.us-east-1.elb.amazonaws.com"
# ============================

dnf install -y nginx

# Copy frontend files from S3
aws s3 cp "s3://${S3_BUCKET}/frontend/" /tmp/frontend/ --recursive
cp /tmp/frontend/index.html /tmp/frontend/style.css /tmp/frontend/app.js /usr/share/nginx/html/

# Minimal nginx.conf (replaces AL2023's default server block)
cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    sendfile on;
    include /etc/nginx/conf.d/*.conf;
}
EOF

# Site config: point /api at the internal ALB
sed "s|\\\${BACKEND_URL}|${BACKEND_URL}|g" /tmp/frontend/nginx.conf.template > /etc/nginx/conf.d/app.conf

# Write this instance's identity so the UI shows which web server responded
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
md() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
cat > /usr/share/nginx/html/web-info.json <<EOF
{"instance": "$(md instance-id)", "az": "$(md placement/availability-zone)", "privateIp": "$(md local-ipv4)"}
EOF

nginx -t
systemctl enable --now nginx
