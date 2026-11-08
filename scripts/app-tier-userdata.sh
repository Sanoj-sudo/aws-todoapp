#!/bin/bash
# EC2 user data for the APP tier (stock Ubuntu 22.04 / 24.04 AMI, private subnet, behind the internal ALB).
# Paste this whole file into: Launch template -> Advanced details -> User data
#
# Requirements:
#   - NAT gateway on the private app subnets (apt, NodeSource, GitHub and npm need internet)
#   - app-sg: allow 4000 from internal-alb-sg
#   - db-sg:  allow 3306 from app-sg
#
# Logs: /var/log/cloud-init-output.log, sudo journalctl -u app
#
# No "set -x": it would print DB_PASSWORD into the logs.
set -euo pipefail

# ================= EDIT THESE =================
# Single quotes keep characters like $ or ! in passwords as-is.
export DB_HOST='your-db.xxxxxxxx.us-east-1.rds.amazonaws.com'   # RDS endpoint, host name only
export DB_PORT='3306'
export DB_USER='admin'
export DB_PASSWORD='ChangeMe123!'
export DB_NAME='appdb'
export JWT_SECRET='replace-with-a-long-random-string'   # openssl rand -hex 32; SAME on all app instances
export REPO_BRANCH='main'
# For a private repo: export REPO_URL='https://<github-token>@github.com/Sanoj-sudo/aws-todoapp.git'
# ==============================================

curl -fsSL -o /tmp/install.sh "https://raw.githubusercontent.com/Sanoj-sudo/aws-todoapp/${REPO_BRANCH}/scripts/install.sh"
bash /tmp/install.sh app
