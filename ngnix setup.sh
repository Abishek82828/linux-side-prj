#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
SITE="${SITE_NAME:-basic-site}"
ROOT="${WEB_ROOT:-/var/www/$SITE}"
DOM="${DOMAIN:-}"      # Set this if you have a real domain name
MAIL="${EMAIL:-}"      # Needed for Let's Encrypt if DOM is set
TZ="${TZ:-UTC}"
NOW="$(TZ="$TZ" date -u '+%Y-%m-%d %H:%M:%S %Z')"

# --- Helpers ---
log(){ echo "[$(date +%H:%M:%S)] $*"; }
warn(){ echo "[$(date +%H:%M:%S)] warn: $*" >&2; }
die(){ echo "[$(date +%H:%M:%S)] err: $*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

# Must be root
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run: sudo $0"

# Function to detect Public IP on AWS/Cloud
pub_ip() {
  local t ip
  # Try AWS IMDSv2
  t="$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
       -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' || true)"
  if [[ -n "$t" ]]; then
    ip="$(curl -sS -H "X-aws-ec2-metadata-token: $t" \
        http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  else
    # Try AWS IMDSv1
    ip="$(curl -sS http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  fi
  # Fallback to external service
  [[ -n "$ip" ]] || ip="$(curl -sS https://checkip.amazonaws.com 2>/dev/null | tr -d ' \n' || true)"
  echo "$ip"
}

# --- 1. Install Packages ---
log "installing packages..."
if has apt-get; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx curl openssl
  [[ -n "$DOM" ]] && apt-get install -y certbot python3-certbot-nginx
elif has dnf; then
  dnf install -y nginx curl openssl
  [[ -n "$DOM" ]] && dnf install -y certbot python3-certbot-nginx || true
elif has yum; then
  yum install -y nginx curl openssl
  if [[ -n "$DOM" ]]; then
    has amazon-linux-extras && amazon-linux-extras install epel -y || true
    yum install -y certbot python3-certbot-nginx || true
  fi
else
  die "no apt/yum/dnf found"
fi

# --- 2. Fix Default Config Conflict ---
# This is critical: remove the default "Welcome to Nginx" site so ours works.
log "removing default nginx config..."
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/default.conf

# Start Nginx
log "starting nginx..."
systemctl enable --now nginx
systemctl is-active --quiet nginx || die "nginx failed to start"

# --- 3. Create Site Files (Modern CSS) ---
log "creating site content..."
mkdir -p "$ROOT"

# Create the HTML file with styled CSS
cat > "$ROOT/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$SITE</title>
    <style>
        body { font-family: system-ui, -apple-system, sans-serif; background-color: #f4f4f9; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; color: #333; }
        .card { background: white; padding: 3rem; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); text-align: center; max-width: 400px; }
        h1 { color: #2563eb; margin-bottom: 0.5rem; }
        p { color: #666; line-height: 1.5; }
        .badge { background: #dcfce7; color: #166534; padding: 5px 12px; border-radius: 20px; font-size: 0.85rem; font-weight: 600; display: inline-block; margin-top: 15px; }
        .info { font-size: 0.8rem; color: #999; margin-top: 20px; border-top: 1px solid #eee; padding-top: 10px;}
    </style>
</head>
<body>
    <div class="card">
        <h1>✅ $SITE is Online</h1>
        <p>Your Nginx server is configured correctly with HTTPS support.</p>
        <span class="badge">● System Active</span>
        
        <div class="info">
            Host: $(hostname -f 2>/dev/null || hostname)<br>
            Deployed: $NOW
        </div>
    </div>
</body>
</html>
EOF

# Set permissions
chown -R www-data:www-data "$ROOT" 2>/dev/null || true
chown -R nginx:nginx "$ROOT" 2>/dev/null || true
chmod -R 755 "$ROOT"

# --- 4. Configure Nginx (Force HTTPS) ---
IP="$(pub_ip)"
NAME="${DOM:-${IP:-YOUR_PUBLIC_IP}}"

if [[ -d /etc/nginx/sites-available ]]; then
  CONF="/etc/nginx/sites-available/$SITE"
else
  CONF="/etc/nginx/conf.d/$SITE.conf"
fi

log "writing nginx config..."
cat > "$CONF" <<EOF
server {
  listen 80;
  server_name $NAME;
  root $ROOT;
  index index.html;
  # Force Redirect to HTTPS
  location / {
      return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl;
  http2 on;
  server_name $NAME;
  root $ROOT;
  index index.html;

  ssl_certificate      /etc/ssl/$SITE.crt;
  ssl_certificate_key /etc/ssl/$SITE.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  location / { try_files \$uri \$uri/ =404; }
}
EOF

# Enable site (Debian/Ubuntu style)
if [[ -d /etc/nginx/sites-enabled ]]; then
  ln -sf "$CONF" "/etc/nginx/sites-enabled/$SITE"
fi

# --- 5. Generate SSL (Self-Signed) ---
log "generating self-signed ssl..."
mkdir -p /etc/ssl
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "/etc/ssl/$SITE.key" \
  -out "/etc/ssl/$SITE.crt" \
  -days 365 \
  -subj "/CN=$NAME" >/dev/null 2>&1

# Test and Reload
nginx -t
systemctl restart nginx

# --- 6. Let's Encrypt (Optional) ---
if [[ -n "$DOM" ]]; then
  if [[ -z "$MAIL" ]]; then
    warn "no EMAIL provided, skipping LetsEncrypt"
  elif ! has certbot; then
    warn "no certbot found, skipping LetsEncrypt"
  else
    log "attempting LetsEncrypt..."
    if certbot --nginx -d "$DOM" -m "$MAIL" --agree-tos --non-interactive --redirect; then
      log "LetsEncrypt success"
      systemctl reload nginx || true
    else
      warn "LetsEncrypt failed, falling back to self-signed"
    fi
  fi
fi

# --- 7. Final Checks ---
log "running checks..."
ok_local="no"
curl -kfsSI https://127.0.0.1 >/dev/null && ok_local="yes"

ok_https="no"
if [[ -n "$DOM" ]]; then
  URL="https://$DOM"
  TLS="letsencrypt (if ok)"
else
  URL="https://${IP:-<public-ip>}"
  TLS="self-signed (browser warning expected)"
  # Check if public IP answers
  if [[ -n "${IP:-}" ]]; then
      # simple check with timeout
      if curl -kfsSI -m 3 "https://$IP" >/dev/null; then
         ok_https="yes"
      fi
  fi
fi

store="$(df -h / | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"

echo
echo "========================================"
echo " ✅ SETUP COMPLETE"
echo "========================================"
echo " Site Name : $SITE"
echo " Directory : $ROOT"
echo " Public IP : ${IP:-unknown}"
echo " URL       : $URL"
echo " TLS Mode  : $TLS"
echo " Local Check: $ok_local"
echo " Ext. Check : $ok_https"
echo " Storage   : $store"
echo "----------------------------------------"

if [[ "$ok_https" == "yes" ]]; then
  echo "SUCCESS: Website is accessible from the internet."
else
  echo "NOTE: If you cannot access the URL above:"
  echo "1. Ensure AWS Security Group allows Port 80 AND 443."
  echo "2. Accept the 'Self-Signed' warning in your browser."
fi
echo "========================================"
