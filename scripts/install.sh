#!/bin/bash
# Installs the Todo app on a stock Ubuntu 22.04 / 24.04 machine. No AMI baking needed.
#
#   sudo bash scripts/install.sh web --env-file frontend/.env   # Nginx + frontend (web tier)
#   sudo bash scripts/install.sh app --env-file backend/.env    # Node.js API      (app tier)
#   sudo bash scripts/install.sh all --env-file backend/.env    # both on one box, for a quick test
#
# Settings come from environment variables, or from a KEY=value file given with --env-file
# (see frontend/.env.example and backend/.env.example). Environment variables override the file.
#
#   web: BACKEND_URL (required)   DNS_RESOLVER (optional, auto-detected)
#   app: DB_HOST DB_USER DB_PASSWORD JWT_SECRET (required)   DB_PORT DB_NAME PORT (optional)
#   both, optional: REPO_URL REPO_BRANCH (where to get the code if not run from a checkout)
#
# Safe to run again: it updates the code and config and restarts the service.
# Logs: /var/log/cloud-init-output.log (when run from user data), journalctl -u app, /var/log/nginx/error.log
#
# No "set -x": it would print DB_PASSWORD and JWT_SECRET into the logs.
set -euo pipefail

usage() {
  echo "Usage: sudo bash install.sh web|app|all [--env-file FILE]" >&2
  exit 1
}

TIER="${1:-}"
[ $# -gt 0 ] && shift
case "$TIER" in web|app|all) ;; *) usage ;; esac

ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) [ $# -ge 2 ] || usage; ENV_FILE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)" >&2; exit 1; }

# Load the env file without overriding variables that are already set in the environment
if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || { echo "Env file not found: $ENV_FILE" >&2; exit 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # strip one pair of surrounding quotes
    if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    [ -z "${!key+x}" ] && export "$key=$val"
  done < "$ENV_FILE"
fi

REPO_URL="${REPO_URL:-https://github.com/Sanoj-sudo/aws-todoapp.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WEB_ROOT=/usr/share/nginx/html
NODE_MAJOR=24

need() {
  local missing=()
  for v in "$@"; do [ -n "${!v:-}" ] || missing+=("$v"); done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required settings: ${missing[*]}" >&2
    echo "Export them or put them in the file passed with --env-file." >&2
    exit 1
  fi
}

# Check settings before installing anything
if [ "$TIER" = app ] || [ "$TIER" = all ]; then
  need DB_HOST DB_USER DB_PASSWORD JWT_SECRET
  DB_PORT="${DB_PORT:-3306}"
  DB_NAME="${DB_NAME:-appdb}"
  PORT="${PORT:-4000}"
fi
if [ "$TIER" = all ]; then
  BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:${PORT}}"
fi
if [ "$TIER" = web ] || [ "$TIER" = all ]; then
  need BACKEND_URL
  BACKEND_URL="${BACKEND_URL%/}"
  case "$BACKEND_URL" in
    http://*|https://*) ;;
    *) echo "BACKEND_URL must start with http:// or https:// (got: $BACKEND_URL)" >&2; exit 1 ;;
  esac
fi

export DEBIAN_FRONTEND=noninteractive
export HOME="${HOME:-/root}"   # cloud-init doesn't always set HOME; npm needs it

# ---------- EC2 metadata (falls back to hostname when not on EC2) ----------
IMDS_TOKEN=$(curl -s --max-time 2 -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
md() {
  if [ -n "$IMDS_TOKEN" ]; then
    curl -sf --max-time 2 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      "http://169.254.169.254/latest/meta-data/$1" || echo unknown
  else
    echo "$2"
  fi
}

# ---------- Get the code ----------
echo ">>> Installing base packages"
apt-get update
apt-get install -y ca-certificates curl git

SELF="${BASH_SOURCE[0]:-}"
CLONED=""
if [ -n "$SELF" ] && [ -f "$(dirname "$SELF")/../backend/server.js" ]; then
  SRC=$(cd "$(dirname "$SELF")/.." && pwd)
  echo ">>> Using local checkout: $SRC"
else
  SRC=$(mktemp -d)
  CLONED="$SRC"
  echo ">>> Cloning $(echo "$REPO_URL" | sed -E 's#://[^@/]+@#://***@#') (${REPO_BRANCH})"
  git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SRC"
fi
cleanup() { if [ -n "$CLONED" ]; then rm -rf "$CLONED"; fi; }   # also removes a token if one was in REPO_URL
trap cleanup EXIT

# ---------- App tier ----------
install_app() {
  echo ">>> [app] Installing Node.js ${NODE_MAJOR} and mysql client"
  apt-get install -y gnupg mysql-client
  if ! command -v node >/dev/null || ! node --version | grep -q "^v${NODE_MAJOR}\."; then
    # Ubuntu's nodejs package is too old on 22.04, so use NodeSource
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  fi
  echo "node $(node --version), npm $(npm --version)"

  echo ">>> [app] Installing the backend into /opt/app"
  id app &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin app
  rm -rf /opt/app
  mkdir -p /opt/app
  cp "$SRC/backend/server.js" "$SRC/backend/package.json" /opt/app/
  cp "$SRC/backend/package-lock.json" /opt/app/ 2>/dev/null || true
  cp "$SRC/database/schema.sql" /opt/app/schema.sql
  (cd /opt/app && npm install --omit=dev --no-audit --no-fund)
  chown -R root:root /opt/app   # the app user only needs to read it

  echo ">>> [app] Writing /etc/app.env (DB host: ${DB_HOST})"
  ( umask 077
    cat > /etc/app.env <<EOF
PORT=${PORT}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
JWT_SECRET=${JWT_SECRET}
EOF
  )
  chown root:root /etc/app.env
  chmod 600 /etc/app.env   # systemd reads it as root before switching to the app user

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

  echo ">>> [app] Waiting for the API on :${PORT}"
  for _ in $(seq 1 30); do
    if curl -fs "http://localhost:${PORT}/health" >/dev/null; then
      echo "API is up"
      curl -s "http://localhost:${PORT}/api/health" || true   # shows whether the DB is reachable
      echo
      return 0
    fi
    sleep 2
  done
  echo "API did not come up; check: journalctl -u app" >&2
  journalctl -u app -n 50 --no-pager >&2 || true
  exit 1
}

# ---------- Web tier ----------
install_web() {
  echo ">>> [web] Installing Nginx and the frontend"
  apt-get install -y nginx

  if [ -z "${DNS_RESOLVER:-}" ]; then
    if [ -n "$IMDS_TOKEN" ]; then
      DNS_RESOLVER=169.254.169.253   # Amazon VPC DNS
    else
      DNS_RESOLVER=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
      DNS_RESOLVER="${DNS_RESOLVER:-127.0.0.53}"
    fi
  fi

  mkdir -p "$WEB_ROOT"
  rm -f "$WEB_ROOT/index.nginx-debian.html"
  cp "$SRC/frontend/index.html" "$SRC/frontend/style.css" "$SRC/frontend/app.js" "$WEB_ROOT/"

  # Ubuntu's default site serves "Welcome to nginx!" on :80
  rm -f /etc/nginx/sites-enabled/default
  sed -e "s|\${BACKEND_URL}|${BACKEND_URL}|g" \
      -e "s|\${DNS_RESOLVER}|${DNS_RESOLVER}|g" \
      "$SRC/frontend/nginx.conf.template" > /etc/nginx/conf.d/app.conf

  # This instance's identity, shown in the UI footer
  cat > "$WEB_ROOT/web-info.json" <<EOF
{"instance": "$(md instance-id "$(hostname)")", "az": "$(md placement/availability-zone local)", "privateIp": "$(md local-ipv4 "$(hostname -I | awk '{print $1}')")"}
EOF

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  echo ">>> [web] Backend: ${BACKEND_URL}  (resolver ${DNS_RESOLVER})"
  curl -fs http://localhost/health >/dev/null && echo "Web tier is up"
  curl -s --max-time 10 http://localhost/api/health || echo "Note: /api/health not reachable yet (is the app tier up?)"
  echo
}

case "$TIER" in
  app) install_app ;;
  web) install_web ;;
  all) install_app; install_web ;;
esac

echo ">>> Done: $TIER"
