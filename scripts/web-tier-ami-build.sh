#!/bin/bash
# Bakes the WEB tier AMI (Nginx + static frontend) on a temporary Ubuntu 22.04 / 24.04 builder.
# Run it ONCE by hand on the builder, then create the AMI from that instance.
#
#   curl -fsSLO https://raw.githubusercontent.com/Sanoj-sudo/aws-todoapp/main/scripts/web-tier-ami-build.sh
#   sudo bash web-tier-ami-build.sh
#   # then: EC2 console -> builder instance -> Actions -> Image -> Create image
#
# The backend URL (internal ALB) is NOT baked in: web-tier-userdata.sh fills it in at boot.
set -euxo pipefail

REPO_URL="${REPO_URL:-https://github.com/Sanoj-sudo/aws-todoapp.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WEB_ROOT=/usr/share/nginx/html   # matches "root" in frontend/nginx.conf.template

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo" >&2; exit 1; fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx curl git

# Get the frontend
SRC=/tmp/aws-todoapp
rm -rf "$SRC"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SRC"

# Static frontend
mkdir -p "$WEB_ROOT"
rm -f "$WEB_ROOT"/index.html "$WEB_ROOT"/index.nginx-debian.html "$WEB_ROOT"/web-info.json
cp "$SRC/frontend/index.html" "$SRC/frontend/style.css" "$SRC/frontend/app.js" "$WEB_ROOT/"

# Keep the template; user data turns it into /etc/nginx/conf.d/app.conf at boot
cp "$SRC/frontend/nginx.conf.template" /etc/nginx/app.conf.template
rm -rf "$SRC"

# Ubuntu's default site serves "Welcome to nginx!" on :80, so remove it
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/app.conf

systemctl enable nginx

# ---- Clean up so every instance launched from the AMI starts fresh ----
apt-get clean
rm -rf /var/lib/apt/lists/*
truncate -s 0 /etc/machine-id
cloud-init clean --logs                  # so user data runs again on every new instance
rm -f /home/ubuntu/.ssh/authorized_keys  # cloud-init adds the launch key pair again on new instances

echo "Web AMI build done. Create the image now (do not reboot the builder first)."
