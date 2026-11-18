#!/usr/bin/env bash
# shpellcast installer for Ubuntu/Debian servers with systemd.
# Safe to re-run: upgrades the binary and keeps your existing settings.
set -euo pipefail

REPO="${SHPELLCAST_REPO:-shpellcast/shpellcast}"
VERSION="${SHPELLCAST_VERSION:-latest}"
CONF_DIR=/etc/shpellcast
CONF="$CONF_DIR/shpellcast.env"
DATA_DIR=/var/lib/shpellcast
BIN=/usr/local/bin/shpellcast
UNIT=/etc/systemd/system/shpellcast.service

PUBLIC_URL=""
PROXY=""
TCP_PORT=""
HTTP_PORT=""
TTL=""
DISK=""
LOCAL_BINARY=""
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

Run with no options for guided questions (needs a terminal).

Options:
  --public-url URL   Address people will open, e.g. https://cast.example.com
  --proxy NAME       none | caddy | nginx   (default: none)
  --tcp-port PORT    Port for nc ingest           (default: 9696)
  --http-port PORT   Port for the web pages        (default: 8080)
  --ttl DURATION     Link lifetime after output stops (default: 24h)
  --disk-save        Keep full output on disk so links survive restarts
  --binary PATH      Install a locally built Linux executable
  --yes              Do not ask for confirmation
  -h, --help         Show this help
EOF
}

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --public-url) PUBLIC_URL="${2:-}"; shift 2 ;;
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --tcp-port) TCP_PORT="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --ttl) TTL="${2:-}"; shift 2 ;;
    --disk-save) DISK=yes; shift ;;
    --binary) [ -n "${2:-}" ] || die "--binary requires a path"; LOCAL_BINARY="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root, for example: curl -fsSL <url> | sudo bash"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"
command -v curl >/dev/null 2>&1 || die "curl is required (sudo apt-get install -y curl)"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac

# Existing settings win over defaults, so re-running never resets them.
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  EXISTING=1
  SHPELLCAST_HTTP_ADDR="${SHPELLCAST_HTTP_ADDR:-:8080}"
  SHPELLCAST_TCP_ADDR="${SHPELLCAST_TCP_ADDR:-:9696}"
  HTTP_PORT="${SHPELLCAST_HTTP_ADDR##*:}"
  TCP_PORT="${SHPELLCAST_TCP_ADDR##*:}"
  PUBLIC_URL="${SHPELLCAST_PUBLIC_URL:-http://localhost:$HTTP_PORT}"
  TTL="${SHPELLCAST_TTL:-24h}"
  DISK=no
  if [ -n "${SHPELLCAST_DATA_DIR:-}" ]; then DISK=yes; fi
else
  EXISTING=0
fi

ask() { # ask "question" default -> sets ANSWER
  local q="$1" def="$2"
  if [ -n "$def" ]; then printf '%s [%s]: ' "$q" "$def" >/dev/tty; else printf '%s: ' "$q" >/dev/tty; fi
  local a=""
  read -r a </dev/tty || true
  ANSWER="${a:-$def}"
}

interactive() { [ "$ASSUME_YES" -eq 0 ] && ( : </dev/tty ) 2>/dev/null; }

DEFAULT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
DEFAULT_IP="${DEFAULT_IP:-127.0.0.1}"

if [ "$EXISTING" -eq 0 ]; then
  if interactive; then
    echo
    echo "shpellcast setup"
    echo "----------------"
    echo "How will people reach it?"
    echo "  1) A domain name with HTTPS (recommended)"
    echo "  2) This server's address over plain HTTP (for trying it out)"
    ask "Choose 1 or 2" "1"
    if [ "$ANSWER" = "1" ]; then
      ask "Domain name, for example cast.example.com" ""
      [ -n "$ANSWER" ] || die "a domain name is needed for HTTPS"
      PUBLIC_URL="https://${ANSWER#https://}"
      PUBLIC_URL="${PUBLIC_URL%/}"
      echo "Which tool should handle HTTPS?"
      echo "  1) Caddy (recommended, certificates are automatic)"
      echo "  2) nginx (certificates via certbot, set up separately)"
      echo "  3) None, I will handle it myself"
      ask "Choose 1, 2 or 3" "1"
      case "$ANSWER" in
        2) PROXY=nginx ;;
        3) PROXY=none ;;
        *) PROXY=caddy ;;
      esac
    else
      PROXY=none
    fi
    if [ -z "$HTTP_PORT" ]; then ask "Web port" "${HTTP_PORT_DEFAULT:-8080}"; HTTP_PORT="$ANSWER"; fi
    if [ -z "$TCP_PORT" ]; then ask "Port for nc" "9696"; TCP_PORT="$ANSWER"; fi
    if [ -z "$TTL" ]; then ask "How long links last after output stops" "24h"; TTL="$ANSWER"; fi
    if [ -z "$DISK" ]; then
      ask "Keep full output on disk so links survive restarts? (y/n)" "y"
      case "$ANSWER" in y|Y|yes) DISK=yes ;; *) DISK=no ;; esac
    fi
  fi
fi

PROXY="${PROXY:-none}"
HTTP_PORT="${HTTP_PORT:-8080}"
TCP_PORT="${TCP_PORT:-9696}"
TTL="${TTL:-24h}"
DISK="${DISK:-yes}"
case "$PROXY" in none|caddy|nginx) ;; *) die "--proxy must be none, caddy or nginx" ;; esac
[ -n "$PUBLIC_URL" ] || PUBLIC_URL="http://$DEFAULT_IP:$HTTP_PORT"
PUBLIC_URL="${PUBLIC_URL%/}"
case "$PUBLIC_URL" in http://*|https://*) ;; *) die "--public-url must start with http:// or https://" ;; esac
case "$TCP_PORT$HTTP_PORT" in *[!0-9]*|"") die "ports must be numbers" ;; esac
DOMAIN="${PUBLIC_URL#*://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN%%:*}"

if [ "$PROXY" = none ]; then BIND_HOST=0.0.0.0; else BIND_HOST=127.0.0.1; fi
if [ "$EXISTING" -eq 1 ]; then BIND_HOST="${SHPELLCAST_HTTP_ADDR%:*}"; fi
case "$BIND_HOST" in
  ""|0.0.0.0) HEALTH_HOST=127.0.0.1 ;;
  '[::]') HEALTH_HOST='[::1]' ;;
  *) HEALTH_HOST="$BIND_HOST" ;;
esac
HEALTH_URL="http://$HEALTH_HOST:$HTTP_PORT/healthz"

echo
echo "Plan:"
echo "  Public address : $PUBLIC_URL"
echo "  Web port       : $HTTP_PORT (listening on $BIND_HOST)"
echo "  nc port        : $TCP_PORT"
echo "  Link lifetime  : $TTL after output stops"
echo "  Disk saving    : $DISK"
echo "  HTTPS          : $PROXY"
if [ "$EXISTING" -eq 1 ]; then echo "  Existing settings in $CONF are kept."; fi
if interactive && [ "$ASSUME_YES" -eq 0 ]; then
  ask "Continue? (y/n)" "y"
  case "$ANSWER" in y|Y|yes) ;; *) echo "Cancelled. Nothing was changed."; exit 0 ;; esac
fi

if [ -n "$LOCAL_BINARY" ]; then
  [ -f "$LOCAL_BINARY" ] && [ -r "$LOCAL_BINARY" ] || die "cannot read binary: $LOCAL_BINARY"
  install -m 0755 -- "$LOCAL_BINARY" "$BIN"
else
  echo "Downloading shpellcast ($ARCH)..."
  if [ "$VERSION" = latest ]; then
    URL="https://github.com/$REPO/releases/latest/download/shpellcast-linux-$ARCH"
  else
    URL="https://github.com/$REPO/releases/download/$VERSION/shpellcast-linux-$ARCH"
  fi
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  curl -fsSL -o "$TMP" "$URL" || die "could not download $URL. Check that the release includes shpellcast-linux-$ARCH, or build from source and use --binary."
  install -m 0755 "$TMP" "$BIN"
fi

id -u shpellcast >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin shpellcast
install -d -m 0750 -o shpellcast -g shpellcast "$DATA_DIR"
install -d -m 0755 "$CONF_DIR"

if [ "$EXISTING" -eq 0 ]; then
  DATA_LINE=""
  [ "$DISK" = yes ] && DATA_LINE="$DATA_DIR"
  umask 077
  cat >"$CONF" <<EOF
# shpellcast settings. Edit, then run: sudo systemctl restart shpellcast
SHPELLCAST_PUBLIC_URL=$PUBLIC_URL
SHPELLCAST_HTTP_ADDR=$BIND_HOST:$HTTP_PORT
SHPELLCAST_TCP_ADDR=0.0.0.0:$TCP_PORT
SHPELLCAST_TTL=$TTL
SHPELLCAST_DATA_DIR=$DATA_LINE
SHPELLCAST_MAX_STREAMS=10000
SHPELLCAST_BUFFER_BYTES=262144
EOF
  chmod 0640 "$CONF"
  chown root:shpellcast "$CONF"
  echo "Saved settings to $CONF"
fi

cat >"$UNIT" <<'EOF'
[Unit]
Description=shpellcast live command output sharing
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=shpellcast
Group=shpellcast
EnvironmentFile=-/etc/shpellcast/shpellcast.env
ExecStart=/usr/local/bin/shpellcast
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
ReadWritePaths=/var/lib/shpellcast

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable shpellcast >/dev/null 2>&1
if ! systemctl restart shpellcast; then
  journalctl -u shpellcast -n 20 --no-pager >&2 || true
  die "systemd could not restart shpellcast"
fi

if [ "$PROXY" = caddy ]; then
  command -v caddy >/dev/null 2>&1 || apt-get install -y caddy || die "could not install Caddy. Install it, then re-run with --proxy caddy."
  CADDYFILE=/etc/caddy/Caddyfile
  if [ -f "$CADDYFILE" ] && ! grep -q "managed by shpellcast" "$CADDYFILE"; then
    cp "$CADDYFILE" "$CADDYFILE.bak-$(date +%s)"
  fi
  cat >"$CADDYFILE" <<EOF
# managed by shpellcast
$DOMAIN {
	reverse_proxy 127.0.0.1:$HTTP_PORT {
		flush_interval -1
	}
}
EOF
  systemctl reload caddy || systemctl restart caddy
elif [ "$PROXY" = nginx ]; then
  command -v nginx >/dev/null 2>&1 || apt-get install -y nginx || die "could not install nginx. Install it, then re-run with --proxy nginx."
  NGX=/etc/nginx/sites-available/shpellcast
  cat >"$NGX" <<EOF
# managed by shpellcast
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;
    location / {
        proxy_pass http://127.0.0.1:$HTTP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
    }
}
EOF
  ln -sf "$NGX" /etc/nginx/sites-enabled/shpellcast
  nginx -t || die "nginx configuration test failed"
  systemctl reload nginx || die "nginx could not reload"
  echo "For HTTPS with nginx, run: sudo apt-get install -y certbot python3-certbot-nginx && sudo certbot --nginx -d $DOMAIN"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$TCP_PORT/tcp" >/dev/null
  if [ "$PROXY" = none ]; then
    case "$BIND_HOST" in 127.*|'[::1]'|localhost) ;; *) ufw allow "$HTTP_PORT/tcp" >/dev/null ;; esac
  fi
  if [ "$PROXY" != none ]; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
  echo "Firewall: opened the needed ports."
fi

ok=0
for _ in 1 2 3 4 5; do
  if curl -fsS --noproxy '*' --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
if [ "$ok" -eq 1 ]; then
  echo
  echo "shpellcast is running."
  echo "  Pages      : $PUBLIC_URL"
  echo "  Send output: <command> | nc $DOMAIN $TCP_PORT"
  echo "  Settings   : $CONF"
  echo "  Logs       : sudo journalctl -u shpellcast -f"
else
  echo
  echo "shpellcast did not answer at $HEALTH_URL. The last log lines:" >&2
  journalctl -u shpellcast -n 20 --no-pager >&2 || true
  exit 1
fi
