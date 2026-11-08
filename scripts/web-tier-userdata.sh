#!/bin/bash
# EC2 user data for the WEB tier (stock Ubuntu 22.04 / 24.04 AMI, public subnet).
# Paste this whole file into: Launch template -> Advanced details -> User data
#
# Requirements:
#   - Outbound internet (public IP auto-assigned, or a NAT gateway) to install Nginx and fetch the code
#   - web-sg:          allow 80 from public-alb-sg
#   - internal-alb-sg: allow 80 from web-sg
#
# Logs: /var/log/cloud-init-output.log, /var/log/nginx/error.log
set -euo pipefail

# ================= EDIT THESE =================
export BACKEND_URL='http://internal-app-alb-xxxxxxxx.us-east-1.elb.amazonaws.com'   # internal ALB DNS, no trailing slash
export REPO_BRANCH='main'
# ==============================================

curl -fsSL -o /tmp/install.sh "https://raw.githubusercontent.com/Sanoj-sudo/aws-todoapp/${REPO_BRANCH}/scripts/install.sh"
bash /tmp/install.sh web
