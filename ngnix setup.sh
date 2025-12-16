#!/usr/bin/env bash
set -euo pipefail

# cfg
SITE="${SITE_NAME:-basic-site}"
ROOT="${WEB_ROOT:-/var/www/$SITE}"
DOM="${DOMAIN:-}"      # set for real https
MAIL="${EMAIL:-}"      # need if DOM set
TZ="${TZ:-UTC}"
NOW="$(TZ="$TZ" date -u '+%Y-%m-%d %H:%M:%S %Z')"

log(){ echo "[$(date +%H:%M:%S)] $*"; }
warn(){ echo "[$(date +%H:%M:%S)] warn: $*" >&2; }
die(){ echo "[$(date +%H:%M:%S)] err: $*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run: sudo $0"

pub_ip() {
  local t ip
  t="$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' || true)"
  if [[ -n "$t" ]]; then
    ip="$(curl -sS -H "X-aws-ec2-metadata-token: $t" \
        http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  else
    ip="$(curl -sS http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  fi
  [[ -n "$ip" ]] || ip="$(curl -sS https://checkip.amazonaws.com 2>/dev/null | tr -d ' \n' || true)"
  echo "$ip"
}

# pkgs
log "install stuff..."
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
  die "no apt/yum/dnf"
fi

# nginx up
log "start nginx..."
systemctl enable --now nginx
systemctl is-active --quiet nginx || die "nginx not up"

# files
log "make site..."
mkdir -p "$ROOT"
chown -R www-data:www-data "$ROOT" 2>/dev/null || true
chown -R nginx:nginx "$ROOT" 2>/dev/null || true

cat > "$ROOT/index.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>$SITE</title></head>
<body style="font-family:Arial,sans-serif">
<h1>✅ nginx is on</h1>
<p><b>site:</b> $SITE</p>
<p><b>host:</b> $(hostname -f 2>/dev/null || hostname)</p>
<p><b>deployed:</b> $NOW</p>
</body></html>
EOF

# conf
IP="$(pub_ip)"
NAME="${DOM:-${IP:-YOUR_PUBLIC_IP}}"

if [[ -d /etc/nginx/sites-available ]]; then
  CONF="/etc/nginx/sites-available/$SITE"
else
  CONF="/etc/nginx/conf.d/$SITE.conf"
fi

log "set nginx conf..."
cat > "$CONF" <<EOF
server {
  listen 80;
  server_name $NAME;
  root $ROOT;
  index index.html;
  location / { try_files \$uri \$uri/ =404; }
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  server_name $NAME;
  root $ROOT;
  index index.html;

  ssl_certificate     /etc/ssl/$SITE.crt;
  ssl_certificate_key /etc/ssl/$SITE.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  location / { try_files \$uri \$uri/ =404; }
}
EOF

if [[ -d /etc/nginx/sites-enabled ]]; then
  ln -sf "$CONF" "/etc/nginx/sites-enabled/$SITE"
  [[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default || true
fi

# tls (temp)
log "make tls (self)..."
mkdir -p /etc/ssl
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "/etc/ssl/$SITE.key" \
  -out "/etc/ssl/$SITE.crt" \
  -days 365 \
  -subj "/CN=$NAME" >/dev/null 2>&1

nginx -t
systemctl reload nginx

# tls (real)
if [[ -n "$DOM" ]]; then
  if [[ -z "$MAIL" ]]; then
    warn "no EMAIL, skip letsencrypt"
  elif ! has certbot; then
    warn "no certbot, skip letsencrypt"
  else
    log "try letsencrypt..."
    if certbot --nginx -d "$DOM" -m "$MAIL" --agree-tos --non-interactive --redirect; then
      log "letsencrypt ok"
      systemctl reload nginx || true
    else
      warn "letsencrypt fail, keep self"
    fi
  fi
fi

# check
log "check..."
ok_local="no"
curl -fsSI http://127.0.0.1 >/dev/null && ok_local="yes"

ok_https="no"
if [[ -n "$DOM" ]]; then
  curl -fsSI "https://$DOM" >/dev/null && ok_https="yes"
  URL="https://$DOM"
  TLS="letsencrypt (if ok) else self"
else
  URL="https://${IP:-<public-ip>}"
  TLS="self (browser warn)"
  if [[ -n "${IP:-}" ]] && curl -kfsSI "https://$IP" >/dev/null; then
    ok_https="yes"
  elif curl -kfsSI https://127.0.0.1 >/dev/null; then
    ok_https="local"
  fi
fi

store="$(df -h / | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"

echo
echo "==== done ===="
echo "site    : $SITE"
echo "dir     : $ROOT"
echo "time    : $NOW"
echo "store   : $store"
echo "nginx   : $(systemctl is-active nginx || true)"
echo "pub ip  : ${IP:-unknown}"
echo "url     : $URL"
echo "tls     : $TLS"
echo "http loc: $ok_local"
echo "https   : $ok_https"
echo "----------"
if [[ "$ok_https" == "yes" ]]; then
  echo "✅ public access ok, website now on"
elif [[ "$ok_https" == "local" ]]; then
  echo "⚠️ https ok on box, public fail: check SG inbound 80/443 + NACL"
else
  echo "⚠️ fail: check nginx, SG 80/443, DNS (if domain)"
fi
echo "============="
