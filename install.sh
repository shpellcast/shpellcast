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
  --proxy NAME       none | external | caddy | nginx (default: none)
                     external binds the web service to loopback for your proxy
  --tcp-port PORT    Port for nc ingest           (default: 9696)
  --http-port PORT   Port for the web pages        (default: 8080)
  --ttl DURATION     Link lifetime after output stops (default: 24h)
  --disk-save        Keep full output on disk so links survive restarts
  --no-disk-save     Keep only recent output in memory
  --binary PATH      Install a locally built Linux executable
  --yes              Skip all prompts
  -h, --help         Show this help
EOF
}

die() { echo "error: $*" >&2; exit 1; }

CAN_PROMPT=0
COLOR=""
RESET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --public-url|--proxy|--tcp-port|--http-port|--ttl|--binary)
      [ -n "${2:-}" ] && [[ "$2" != -* ]] || die "$1 requires a value" ;;
  esac
  case "$1" in
    --public-url) PUBLIC_URL="${2:-}"; shift 2 ;;
    --proxy)
      case "$2" in none|external|caddy|nginx) PROXY="$2" ;; *) die "--proxy must be none, external, caddy, or nginx" ;; esac
      shift 2 ;;
    --tcp-port) TCP_PORT="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --ttl) TTL="${2:-}"; shift 2 ;;
    --disk-save) DISK=yes; shift ;;
    --no-disk-save) DISK=no; shift ;;
    --binary) LOCAL_BINARY="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$ASSUME_YES" -eq 0 ] && { exec 3<>/dev/tty; } 2>/dev/null && [ -t 3 ]; then
  CAN_PROMPT=1
fi
if [ -t 2 ] && [ -n "${TERM:-}" ] && [ "$TERM" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR=$'\033[32m'
  RESET=$'\033[0m'
fi

[ "$(id -u)" -eq 0 ] || die "run as root, for example: curl -fsSL <url> | sudo bash"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"
command -v curl >/dev/null 2>&1 || die "curl is required (sudo apt-get install -y curl)"
command -v flock >/dev/null 2>&1 || die "flock is required (sudo apt-get install -y util-linux)"
exec 9>/run/lock/shpellcast-install.lock
flock -n 9 || die "another shpellcast installation is running"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac

# Read only the values needed for the upgrade summary and local health check.
# EnvironmentFile syntax does not imply shell evaluation.
read_setting() {
  local key="$1" line value=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:blank:]]*"$key"[[:blank:]]*=[[:blank:]]*(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value%"${value##*[![:space:]]}"}"
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
    fi
  done <"$CONF"
  printf '%s' "${value:-$2}"
}

# Existing settings win over flags and defaults.
if [ -f "$CONF" ]; then
  EXISTING=1
  SHPELLCAST_HTTP_ADDR="$(read_setting SHPELLCAST_HTTP_ADDR :8080)"
  SHPELLCAST_TCP_ADDR="$(read_setting SHPELLCAST_TCP_ADDR :9696)"
  HTTP_PORT="${SHPELLCAST_HTTP_ADDR##*:}"
  TCP_PORT="${SHPELLCAST_TCP_ADDR##*:}"
  PUBLIC_URL="$(read_setting SHPELLCAST_PUBLIC_URL "http://localhost:$HTTP_PORT")"
  TTL="$(read_setting SHPELLCAST_TTL 24h)"
  DISK=no
  if [ -n "$(read_setting SHPELLCAST_DATA_DIR '')" ]; then DISK=yes; fi
  case "$PROXY" in caddy|nginx) ;; *) PROXY=existing ;; esac
else
  EXISTING=0
fi

ask() { # ask "question" default -> sets ANSWER
  local q="$1" def="$2"
  if [ -n "$def" ]; then printf '%s [%s]: ' "$q" "$def" >&3; else printf '%s: ' "$q" >&3; fi
  local a=""
  read -r a <&3 || die "no input from terminal; for automation pass --public-url URL --yes"
  ANSWER="${a:-$def}"
}

interactive() { [ "$CAN_PROMPT" -eq 1 ]; }

valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
valid_ttl() {
  local duration='^\+?(([0-9]+(\.[0-9]*)?|\.[0-9]+)(ns|us|µs|μs|ms|s|m|h))+$'
  [[ "$1" =~ $duration && "$1" =~ [1-9] ]] || return 1
  # Check the combined duration before Go converts it to signed nanoseconds.
  LC_ALL=C awk -v value="${1#+}" '
    BEGIN {
      units["h"] = 3600000000000; units["m"] = 60000000000
      units["s"] = 1000000000; units["ms"] = 1000000
      units["us"] = units["µs"] = units["μs"] = 1000; units["ns"] = 1
      while (match(value, /^[0-9.]+/)) {
        number = substr(value, 1, RLENGTH)
        value = substr(value, RLENGTH + 1)
        match(value, /^[^0-9.]+/)
        total += int(number * units[substr(value, 1, RLENGTH)])
        value = substr(value, RLENGTH + 1)
      }
      exit !(total >= 1 && total < 9223372036854775808)
    }'
}
valid_yes_no() { case "${1,,}" in y|yes|n|no) return 0 ;; *) return 1 ;; esac; }
valid_scheme() { [ "$1" = http ] || [ "$1" = https ]; }
valid_proxy() { case "$1" in none|external|caddy|nginx) return 0 ;; *) return 1 ;; esac; }
valid_public_proxy() {
  valid_proxy "$1" || return 1
  case "$1" in
    caddy) [ "$URL_SCHEME" = https ] && { [ -z "$URL_PORT" ] || [ "$URL_PORT" = 443 ]; } ;;
    nginx) [ -z "$URL_PORT" ] || [ "$URL_SCHEME:$URL_PORT" = http:80 ] || [ "$URL_SCHEME:$URL_PORT" = https:443 ] ;;
  esac
}
valid_local_port() {
  valid_port "$1" || return 1
  case "$PROXY:$1" in caddy:80|caddy:443|nginx:80|nginx:443) return 1 ;; esac
  return 0
}
valid_web_port() {
  valid_local_port "$1" && [ "$1" != "$TCP_PORT" ]
}
parse_url() {
  local pattern='^(https?)://([a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)(:([0-9]+))?/?$'
  [[ "$1" =~ $pattern ]] || return 1
  URL_SCHEME="${BASH_REMATCH[1]}"
  DOMAIN="${BASH_REMATCH[2]}"
  URL_PORT="${BASH_REMATCH[5]}"
  local label
  local -a labels
  IFS=. read -ra labels <<<"$DOMAIN"
  [ "${#DOMAIN}" -le 253 ] || return 1
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
  done
  [ -z "$URL_PORT" ] || valid_port "$URL_PORT"
}

ask_valid() {
  local question="$1" default="$2" validator="$3" hint="$4"
  while :; do
    ask "$question" "$default"
    "$validator" "$ANSWER" && return 0
    printf '%s\n' "$hint" >&3
  done
}

if [ "$EXISTING" -eq 0 ]; then
  URL_FROM_WIZARD=no
  if interactive; then
    printf '\n%s     *\n    /\\    shpellcast setup\n   /__\\   Prepare your portal.\n%s\n' "$COLOR" "$RESET" >&3
    if [ -z "$PUBLIC_URL" ]; then
      printf '%s\n' 'HTTPS is recommended for shared links. HTTP is for local or trusted-network setups.' \
        'For public HTTPS, point your domain at the server or reverse proxy before testing the link.' >&3
      ask_valid "How should browsers connect? (https/http)" https valid_scheme "Choose https or http."
      SCHEME="$ANSWER"
      DEFAULT_HOST=""
      if [ "$SCHEME" = http ]; then
        DEFAULT_HOST="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
        if [[ ! "$DEFAULT_HOST" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then DEFAULT_HOST=localhost; fi
      fi
      while :; do
        ask "Public hostname or URL, e.g. cast.example.com" "$DEFAULT_HOST"
        case "$ANSWER" in *://*) PUBLIC_URL="$ANSWER" ;; *) PUBLIC_URL="$SCHEME://$ANSWER" ;; esac
        if parse_url "$PUBLIC_URL" && [ "$URL_SCHEME" = "$SCHEME" ]; then break; fi
        printf 'Enter a hostname or a %s:// URL without a path, query, or credentials.\n' "$SCHEME" >&3
      done
      URL_FROM_WIZARD=yes
    fi
    parse_url "$PUBLIC_URL" || die "--public-url must be an HTTP(S) origin with a hostname and optional port"
    if [ -z "$PROXY" ]; then
      if [ "$URL_SCHEME" = https ]; then
        printf '%s\n' 'Caddy gets certificates automatically. nginx requires a separate certificate step.' \
          'Choose external for a proxy on this server, or none if a proxy on another host handles HTTPS.' >&3
        DEFAULT_PROXY=caddy
        if [ -n "$URL_PORT" ] && [ "$URL_PORT" != 443 ]; then DEFAULT_PROXY=external; fi
        ask_valid "Who should handle HTTPS? (caddy/nginx/external/none)" "$DEFAULT_PROXY" valid_public_proxy "Choose external or none for custom public ports. Otherwise choose caddy, nginx, external, or none."
      else
        ask_valid "Serve HTTP directly (none), through nginx, or through your own local proxy (external)?" none valid_public_proxy "Choose external or none for custom public ports. Otherwise choose nginx, external, or none."
      fi
      PROXY="$ANSWER"
    fi
    PORT_HINT="Enter a port from 1 to 65535."
    case "$PROXY" in caddy|nginx) PORT_HINT="$PORT_HINT Leave 80 and 443 free for the proxy." ;; esac
    if [ -z "$HTTP_PORT" ]; then
      DEFAULT_HTTP_PORT=8080
      if [ "$PROXY" = none ] && [ "$URL_SCHEME" = http ] && [ -n "$URL_PORT" ]; then DEFAULT_HTTP_PORT="$URL_PORT"; fi
      if [ "$DEFAULT_HTTP_PORT" = "$TCP_PORT" ]; then DEFAULT_HTTP_PORT=8081; fi
      ask_valid "Local web port (the proxy forwards here, if enabled)" "$DEFAULT_HTTP_PORT" valid_web_port "$PORT_HINT Use a different port from nc."
      HTTP_PORT="$ANSWER"
    fi
    if [ -z "$TCP_PORT" ]; then
      DEFAULT_TCP_PORT=9696
      if [ "$HTTP_PORT" = "$DEFAULT_TCP_PORT" ]; then DEFAULT_TCP_PORT=9697; fi
      while :; do
        ask_valid "TCP port for nc (raw command output)" "$DEFAULT_TCP_PORT" valid_local_port "$PORT_HINT"
        TCP_PORT="$ANSWER"
        [ "$TCP_PORT" != "$HTTP_PORT" ] && break
        printf '%s\n' 'Choose a port different from the web port.' >&3
      done
    fi
    if [ -z "$TTL" ]; then
      ask_valid "How long should links last after output stops?" 24h valid_ttl "Enter a positive duration such as 60m, 24h, or 1h30m."
      TTL="$ANSWER"
    fi
    if [ -z "$DISK" ]; then
      ask_valid "Save full output on disk so links survive restarts? (y/n)" y valid_yes_no "Choose y or n."
      case "${ANSWER,,}" in y|yes) DISK=yes ;; *) DISK=no ;; esac
    fi
  fi

  [ -n "$PUBLIC_URL" ] || die "a fresh unattended install requires --public-url URL; run from a terminal for the wizard"
  HTTP_PORT="${HTTP_PORT:-8080}"
  TCP_PORT="${TCP_PORT:-9696}"
  TTL="${TTL:-24h}"
  DISK="${DISK:-yes}"
  PROXY="${PROXY:-none}"
  valid_proxy "$PROXY" || die "--proxy must be none, external, caddy, or nginx"
  valid_port "$HTTP_PORT" && valid_port "$TCP_PORT" || die "ports must be integers from 1 to 65535"
  [ "$HTTP_PORT" != "$TCP_PORT" ] || die "the TCP and web ports must be different"
  valid_ttl "$TTL" || die "--ttl must be a positive duration such as 60m, 24h, or 1h30m"
  parse_url "$PUBLIC_URL" || die "--public-url must be an HTTP(S) origin with a hostname and optional port"
  PUBLIC_URL="${PUBLIC_URL%/}"
  if [ "$PROXY" = none ]; then
    BIND_HOST=0.0.0.0
    if [ "$URL_FROM_WIZARD" = yes ] && [ "$URL_SCHEME" = http ] && [ -z "$URL_PORT" ] && [ "$HTTP_PORT" != 80 ]; then
      PUBLIC_URL="$PUBLIC_URL:$HTTP_PORT"
    fi
  else
    BIND_HOST=127.0.0.1
  fi
else
  BIND_HOST="${SHPELLCAST_HTTP_ADDR%:*}"
  DOMAIN="${PUBLIC_URL#*://}"
  DOMAIN="${DOMAIN%%/*}"
  case "$DOMAIN" in
    \[*\]*) DOMAIN="${DOMAIN#\[}"; DOMAIN="${DOMAIN%%\]*}" ;;
    *) DOMAIN="${DOMAIN%%:*}" ;;
  esac
fi
case "$PROXY" in
  caddy|nginx)
    parse_url "$PUBLIC_URL" || die "managed proxy setup needs an HTTP(S) origin with a hostname"
    [ "$PROXY" != caddy ] || [ "$URL_SCHEME" = https ] || die "Caddy setup requires an HTTPS public URL"
    DEFAULT_PUBLIC_PORT=80
    if [ "$URL_SCHEME" = https ]; then DEFAULT_PUBLIC_PORT=443; fi
    [ -z "$URL_PORT" ] || [ "$URL_PORT" = "$DEFAULT_PUBLIC_PORT" ] || die "a managed proxy uses public ports 80 and 443"
    for port in "$HTTP_PORT" "$TCP_PORT"; do
      [ "$port" != 80 ] && [ "$port" != 443 ] || die "the local web and nc ports must leave ports 80 and 443 free for the proxy"
    done
    case "$BIND_HOST" in
      ""|0.0.0.0|127.0.0.1|localhost|'[::]') ;;
      *) die "managed proxy setup needs the app reachable at 127.0.0.1:$HTTP_PORT" ;;
    esac ;;
  none|external|existing) ;;
  *) die "--proxy must be none, external, caddy, or nginx" ;;
esac
case "$BIND_HOST" in
  ""|0.0.0.0) HEALTH_HOST=127.0.0.1 ;;
  '[::]') HEALTH_HOST='[::1]' ;;
  *) HEALTH_HOST="$BIND_HOST" ;;
esac
HEALTH_URL="http://$HEALTH_HOST:$HTTP_PORT/healthz"

print_plan() {
  printf '\nInstallation plan\n'
  printf '  Public address : %s\n' "$PUBLIC_URL"
  printf '  Web port       : %s (listening on %s)\n' "$HTTP_PORT" "${BIND_HOST:-all interfaces}"
  printf '  nc port        : %s\n' "$TCP_PORT"
  printf '  Link lifetime  : %s after output stops\n' "$TTL"
  printf '  Disk saving    : %s\n' "$DISK"
  printf '  Reverse proxy  : %s\n' "$PROXY"
  if [ "$EXISTING" -eq 1 ]; then echo "  Using existing configuration in $CONF."; fi
}
if interactive; then
  print_plan >&3
  ask_valid "Ready to open the portal? Apply this plan (y/n)" n valid_yes_no "Choose y or n."
  case "${ANSWER,,}" in y|yes) ;; *) echo "Installation cancelled."; exit 0 ;; esac
else
  print_plan
fi

WORK_DIR="$(mktemp -d)"
SPINNER_PID=""
STAGED_BINARY=""
cleanup() {
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    printf '\r\033[2K' >&2
  fi
  if [ -n "$STAGED_BINARY" ]; then rm -f -- "$STAGED_BINARY"; fi
  rm -f -- "$WORK_DIR/binary" "$WORK_DIR/step.log" "$WORK_DIR/shpellcast.env"
  rmdir -- "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_step() {
  local label="$1" spell="$2" status=0
  shift 2
  if ! interactive || [ ! -t 2 ] || [ -z "${TERM:-}" ] || [ "$TERM" = dumb ] || [ -n "${SHPELLCAST_REDUCED_MOTION:-}" ]; then
    printf '%s...\n' "$label" >&2
    "$@"
    return
  fi
  (
    while :; do
      for mark in '.' '..' '...'; do
        printf '\r\033[2K%s%s%s %s' "$COLOR" "$mark" "$RESET" "$spell" >&2
        sleep 0.15
      done
    done
  ) &
  SPINNER_PID=$!
  "$@" >"$WORK_DIR/step.log" 2>&1 || status=$?
  kill "$SPINNER_PID" 2>/dev/null || true
  wait "$SPINNER_PID" 2>/dev/null || true
  SPINNER_PID=""
  printf '\r\033[2K' >&2
  if [ "$status" -ne 0 ]; then
    cat "$WORK_DIR/step.log" >&2
    return "$status"
  fi
  printf '%s%s%s\n' "$COLOR" "$label" "$RESET" >&2
}

if [ -n "$LOCAL_BINARY" ]; then
  [ -f "$LOCAL_BINARY" ] && [ -r "$LOCAL_BINARY" ] || die "cannot read binary: $LOCAL_BINARY"
else
  if [ "$VERSION" = latest ]; then
    URL="https://github.com/$REPO/releases/latest/download/shpellcast-linux-$ARCH"
  else
    URL="https://github.com/$REPO/releases/download/$VERSION/shpellcast-linux-$ARCH"
  fi
  LOCAL_BINARY="$WORK_DIR/binary"
  run_step "Download shpellcast ($ARCH)" "Summoning the shpellcast binary..." \
    curl -fsSL -o "$LOCAL_BINARY" "$URL" || die "could not download $URL. Check that the release includes shpellcast-linux-$ARCH, or build from source and use --binary."
fi
STAGED_BINARY="$(mktemp "${BIN}.XXXXXX")"
run_step "Install shpellcast binary" "Preparing your wand..." install -m 0755 -- "$LOCAL_BINARY" "$STAGED_BINARY"
mv -fT -- "$STAGED_BINARY" "$BIN"
STAGED_BINARY=""

prepare_settings() {
  id -u shpellcast >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin shpellcast || return
  install -d -m 0750 -o shpellcast -g shpellcast "$DATA_DIR" || return
  install -d -m 0755 "$CONF_DIR" || return

  if [ "$EXISTING" -eq 0 ]; then
    local disk_path=""
    if [ "$DISK" = yes ]; then disk_path="$DATA_DIR"; fi
    cat >"$WORK_DIR/shpellcast.env" <<EOF || return
# shpellcast settings. Edit, then run: sudo systemctl restart shpellcast
SHPELLCAST_PUBLIC_URL=$PUBLIC_URL
SHPELLCAST_HTTP_ADDR=$BIND_HOST:$HTTP_PORT
SHPELLCAST_TCP_ADDR=0.0.0.0:$TCP_PORT
SHPELLCAST_TTL=$TTL
SHPELLCAST_DATA_DIR=$disk_path
SHPELLCAST_MAX_STREAMS=10000
SHPELLCAST_BUFFER_BYTES=262144
EOF
    install -m 0640 -o root -g shpellcast "$WORK_DIR/shpellcast.env" "$CONF"
  fi
}
run_step "Prepare service account and settings" "Writing the setup scroll..." prepare_settings

if [ ! -f "$UNIT" ]; then
  # The service runs unprivileged. Grant bind capability only when needed.
  BIND_CAPABILITY=""
  if [ "$HTTP_PORT" -lt 1024 ] || [ "$TCP_PORT" -lt 1024 ]; then
    BIND_CAPABILITY=$'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'
  fi
  cat >"$UNIT" <<EOF
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
$BIND_CAPABILITY
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
fi

run_step "Load systemd configuration" "Unrolling the service scroll..." systemctl daemon-reload
run_step "Enable shpellcast at boot" "Setting the wake-up charm..." systemctl enable shpellcast
if ! run_step "Start shpellcast service" "Waking the portal keeper..." systemctl restart shpellcast; then
  journalctl -u shpellcast -n 20 --no-pager >&2 || true
  die "systemd could not restart shpellcast"
fi

if [ "$PROXY" = caddy ]; then
  command -v caddy >/dev/null 2>&1 || run_step "Install Caddy" "Summoning dependencies..." env DEBIAN_FRONTEND=noninteractive apt-get install -y caddy || die "could not install Caddy; install it and retry with --proxy caddy"
  CADDYFILE=/etc/caddy/Caddyfile
  if [ -f "$CADDYFILE" ] && grep -Fq "# managed by shpellcast" "$CADDYFILE"; then
    echo "Existing shpellcast Caddy configuration kept."
  else
    CADDY_CONFIG="$(mktemp /etc/caddy/.shpellcast.XXXXXX)"
    if [ -f "$CADDYFILE" ]; then cat "$CADDYFILE" >"$CADDY_CONFIG"; fi
    cat >>"$CADDY_CONFIG" <<EOF

# managed by shpellcast
$DOMAIN {
	reverse_proxy 127.0.0.1:$HTTP_PORT {
		flush_interval -1
	}
}
EOF
    if ! run_step "Validate Caddy configuration" "Tracing the route to your portal..." caddy validate --config "$CADDY_CONFIG" --adapter caddyfile; then
      rm -f -- "$CADDY_CONFIG"
      die "Caddy configuration test failed; existing Caddyfile was kept"
    fi
    if [ -f "$CADDYFILE" ]; then
      cp -p "$CADDYFILE" "$CADDYFILE.bak-$(date +%s)"
      chmod --reference="$CADDYFILE" "$CADDY_CONFIG"
      chown --reference="$CADDYFILE" "$CADDY_CONFIG"
    else
      chmod 0644 "$CADDY_CONFIG"
    fi
    mv -- "$CADDY_CONFIG" "$CADDYFILE"
  fi
  run_step "Apply Caddy configuration" "Opening the HTTPS doorway..." systemctl reload-or-restart caddy
elif [ "$PROXY" = nginx ]; then
  command -v nginx >/dev/null 2>&1 || run_step "Install nginx" "Summoning dependencies..." env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx || die "could not install nginx; install it and retry with --proxy nginx"
  NGX=/etc/nginx/sites-available/shpellcast
  if [ ! -f "$NGX" ]; then
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
  fi
  LINKED_NGX=no
  if [ ! -e /etc/nginx/sites-enabled/shpellcast ] && [ ! -L /etc/nginx/sites-enabled/shpellcast ]; then
    ln -s "$NGX" /etc/nginx/sites-enabled/shpellcast
    LINKED_NGX=yes
  fi
  if ! run_step "Validate nginx configuration" "Tracing the route to your portal..." nginx -t; then
    if [ "$LINKED_NGX" = yes ]; then rm -- /etc/nginx/sites-enabled/shpellcast; fi
    die "nginx configuration test failed"
  fi
  run_step "Apply nginx configuration" "Opening the web doorway..." systemctl reload nginx || die "nginx could not reload"
  if [ "$URL_SCHEME" = https ]; then
    echo "For HTTPS with nginx, run: sudo apt-get install -y certbot python3-certbot-nginx && sudo certbot --nginx -d $DOMAIN"
  fi
fi

if [ "$PROXY" != existing ] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$TCP_PORT/tcp" >/dev/null
  if [ "$PROXY" = none ]; then
    case "$BIND_HOST" in 127.*|'[::1]'|localhost) ;; *) ufw allow "$HTTP_PORT/tcp" >/dev/null ;; esac
  fi
  case "$PROXY" in caddy|nginx) ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null ;; esac
  echo "Firewall: opened the needed ports."
fi

check_health() {
  local attempt reply
  for attempt in 1 2 3 4 5; do
    if systemctl is-active --quiet shpellcast &&
       reply="$(curl -fsS --noproxy '*' --max-time 2 "$HEALTH_URL" 2>/dev/null)" &&
       [ "$reply" = ok ]; then
      return 0
    fi
    if [ "$attempt" -lt 5 ]; then sleep 1; fi
  done
  return 1
}

if run_step "Check local service health" "The portal is nearly ready..." check_health; then
  echo
  if interactive; then
    printf '%s  ✨  Your portal is awake.%s\n' "$COLOR" "$RESET" >&3
  fi
  echo "  Service    : shpellcast is running"
  echo "  Portal URL : $PUBLIC_URL"
  echo "  Local check: $HEALTH_URL"
  echo "  Send output: <command> | nc $DOMAIN $TCP_PORT"
  echo "  Status     : sudo systemctl status shpellcast"
  echo "  Settings   : $CONF"
  echo "  Logs       : sudo journalctl -u shpellcast -f"
  if [ "$PROXY" = external ]; then
    echo "  Proxy setup: forward to http://127.0.0.1:$HTTP_PORT with streaming buffers disabled"
  fi
  if [ "$PROXY" != none ] || [[ "$PUBLIC_URL" == https://* ]]; then
    echo "  Public test: curl -fsS ${PUBLIC_URL%/}/healthz (once DNS and your proxy are ready)"
  fi
else
  echo
  echo "shpellcast did not answer at $HEALTH_URL. The last log lines:" >&2
  journalctl -u shpellcast -n 20 --no-pager >&2 || true
  exit 1
fi
