#!/bin/bash
# EC2 user data for the APP tier (Ubuntu 22.04 / 24.04, private subnet, behind the internal ALB).
# One script, no AMI and no S3: installs Node.js, pulls the backend from GitHub,
# writes the RDS connection settings and starts the API as a systemd service.
#
# Paste this whole file into: Launch template -> Advanced details -> User data
#
# Requirements:
#   - NAT Gateway on the private app subnets (apt, NodeSource, GitHub and npm need internet)
#   - app-sg: allow 4000 from internal-alb-sg
#   - db-sg:  allow 3306 from app-sg
#
# Logs: /var/log/cloud-init-output.log (this script), sudo journalctl -u app (the API)
#
# No "set -x": it would print DB_PASSWORD into /var/log/cloud-init-output.log.
set -euo pipefail

# ================= EDIT THESE =================
# Use single quotes so characters like $ or ! in passwords are kept as-is.
DB_HOST='your-db.xxxxxxxx.us-east-1.rds.amazonaws.com'   # RDS endpoint, host name only (no mysql://, no :3306)
DB_PORT='3306'
DB_USER='admin'
DB_PASSWORD='ChangeMe123!'
DB_NAME='appdb'
JWT_SECRET='replace-with-a-long-random-string'   # openssl rand -hex 32; MUST be the same on all app instances

# Where the code comes from. For a private repo use
#   https://<github-token>@github.com/Sanoj-sudo/aws-todoapp.git
REPO_URL='https://github.com/Sanoj-sudo/aws-todoapp.git'
REPO_BRANCH='main'
NODE_MAJOR=24   # current LTS; Node 20 is end-of-life
# ==============================================

export DEBIAN_FRONTEND=noninteractive
export HOME=/root   # cloud-init doesn't always set HOME; npm needs it

echo ">>> Installing packages"
apt-get update
apt-get install -y ca-certificates curl gnupg git mysql-client

if ! command -v node >/dev/null || ! node --version | grep -q "^v${NODE_MAJOR}\."; then
  # Ubuntu's own nodejs package is too old on 22.04, so use NodeSource
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi
echo "node $(node --version), npm $(npm --version)"

echo ">>> Fetching the backend from ${REPO_URL} (${REPO_BRANCH})"
id app &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin app
rm -rf /tmp/aws-todoapp /opt/app
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" /tmp/aws-todoapp
mkdir -p /opt/app
cp /tmp/aws-todoapp/backend/server.js /tmp/aws-todoapp/backend/package.json /opt/app/
cp /tmp/aws-todoapp/backend/package-lock.json /opt/app/ 2>/dev/null || true
cp /tmp/aws-todoapp/database/schema.sql /opt/app/schema.sql
rm -rf /tmp/aws-todoapp   # also removes a token if one was in REPO_URL

echo ">>> Installing npm dependencies"
cd /opt/app
npm install --omit=dev --no-audit --no-fund
chown -R root:root /opt/app   # the app user only needs to read it

echo ">>> Writing /etc/app.env (DB host: ${DB_HOST})"
umask 077
cat > /etc/app.env <<EOF
PORT=4000
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
JWT_SECRET=${JWT_SECRET}
EOF
chown root:root /etc/app.env
chmod 600 /etc/app.env   # systemd reads it as root before switching to the app user
umask 022

echo ">>> Creating the systemd service"
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
User=app
Group=app

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable app
systemctl restart app

echo ">>> Waiting for the API on :4000"
for i in $(seq 1 30); do
  if curl -fs http://localhost:4000/health >/dev/null; then
    echo "API is up"
    curl -s http://localhost:4000/api/health || true   # shows whether RDS is reachable
    echo
    exit 0
  fi
  sleep 2
done
echo "API did not come up; check: journalctl -u app" >&2
journalctl -u app -n 50 --no-pager >&2 || true
exit 1
