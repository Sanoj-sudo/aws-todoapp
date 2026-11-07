#!/bin/bash
# Bakes the WEB tier AMI (Nginx + static frontend) on a temporary Ubuntu 22.04 / 24.04 builder.
# Run it ONCE on the builder, then create the AMI from that instance.
#
#   scp -r frontend scripts ubuntu@<builder-ip>:~/aws-todoapp/   (or git clone on the builder)
#   sudo bash ~/aws-todoapp/scripts/web-tier-ami-build.sh ~/aws-todoapp
#   # then: EC2 console -> builder instance -> Actions -> Image -> Create image
#
# The backend URL (internal ALB) is NOT baked in: user data fills it in at boot
# (see web-tier-userdata.sh).
set -euxo pipefail

SRC_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
WEB_ROOT=/usr/share/nginx/html   # matches "root" in frontend/nginx.conf.template

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx curl

# Static frontend
mkdir -p "$WEB_ROOT"
rm -f "$WEB_ROOT"/index.html "$WEB_ROOT"/web-info.json
cp "$SRC_DIR/frontend/index.html" "$SRC_DIR/frontend/style.css" "$SRC_DIR/frontend/app.js" "$WEB_ROOT/"

# Keep the template; user data turns it into /etc/nginx/conf.d/app.conf at boot
cp "$SRC_DIR/frontend/nginx.conf.template" /etc/nginx/app.conf.template

# Ubuntu's default site also listens on :80, so remove it
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/app.conf

systemctl enable nginx

# ---- Clean up so every instance launched from the AMI starts fresh ----
apt-get clean
rm -rf /var/lib/apt/lists/*
truncate -s 0 /etc/machine-id
cloud-init clean --logs
rm -f /home/ubuntu/.ssh/authorized_keys

echo "Web AMI build done. Create the image now (do not reboot the builder first)."
