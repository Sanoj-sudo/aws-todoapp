#!/bin/bash
# EC2 user-data for the APP tier (Amazon Linux 2023, private subnet / behind internal ALB).
# Requirements:
#   - NAT Gateway (or VPC endpoints) so the instance can reach dnf/npm and S3
#   - Instance profile (IAM role) with s3:GetObject / s3:ListBucket on S3_BUCKET
#   - Security group: allow 4000 from the internal ALB security group
#   - RDS security group: allow 3306 from THIS (app tier) security group
set -euxo pipefail

# ======== EDIT THESE ========
S3_BUCKET="my-three-tier-app-bucket"
DB_HOST="your-db.xxxxxxxx.us-east-1.rds.amazonaws.com"
DB_USER="admin"
DB_PASSWORD="ChangeMe123!"   # for real use, fetch from Secrets Manager / SSM instead
DB_NAME="appdb"
JWT_SECRET="replace-with-a-long-random-string"   # MUST be the same on all app instances
# ============================

dnf install -y nodejs npm

mkdir -p /opt/app
aws s3 cp "s3://${S3_BUCKET}/backend/" /opt/app/ --recursive
cd /opt/app
npm install --omit=dev

cat > /etc/app.env <<EOF
PORT=4000
DB_HOST=${DB_HOST}
DB_PORT=3306
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
JWT_SECRET=${JWT_SECRET}
EOF
chmod 600 /etc/app.env

cat > /etc/systemd/system/app.service <<'EOF'
[Unit]
Description=Three-tier Todo API
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/app.env
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
User=nobody

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now app
