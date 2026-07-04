#!/usr/bin/env bash
#
# Breeze Core — reverse-proxy deployment wizard.
#
# Generates and installs a hardened nginx or Apache vhost that fronts a
# loopback-bound Breeze Core, gates the admin endpoints to your LAN,
# overwrites X-Forwarded-For safely, rate-limits, and (optionally) obtains
# a Let's Encrypt certificate. Run with --dry-run first to see exactly what
# it would write and run, changing nothing.
#
# Usage:
#   ./reverse-proxy-wizard.sh [options]
#     --server nginx|apache     web server (asked if omitted)
#     --domain  breeze.example.com
#     --upstream host:port      Breeze Core address (default 127.0.0.1:8420)
#     --lan CIDR[,CIDR...]      networks allowed to hit admin endpoints
#                               (default 192.168.0.0/16,127.0.0.1)
#     --cert certbot|existing|none   TLS strategy (default certbot)
#     --email you@example.com   for certbot registration
#     --cert-file / --key-file  paths, when --cert existing
#     --dry-run                 print actions, make no changes
#     --yes                     don't prompt (fail if a required value is missing)
#     -h, --help
#
# For acme.sh users: issue/install your cert with acme.sh (see
# docs/REVERSE-PROXY.md), then re-run this with --cert existing --cert-file … --key-file …

set -euo pipefail

SERVER="" DOMAIN="" UPSTREAM="127.0.0.1:8420" LAN="192.168.0.0/16,127.0.0.1"
CERT="certbot" EMAIL="" CERT_FILE="" KEY_FILE="" DRYRUN=0 YES=0

C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
say()  { printf "%s==>%s %s\n" "$C_G" "$C_0" "$*"; }
warn() { printf "%s!! %s%s\n" "$C_Y" "$*" "$C_0"; }
die()  { printf "%serror:%s %s\n" "$C_R" "$C_0" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)   SERVER="$2"; shift 2;;
    --domain)   DOMAIN="$2"; shift 2;;
    --upstream) UPSTREAM="$2"; shift 2;;
    --lan)      LAN="$2"; shift 2;;
    --cert)     CERT="$2"; shift 2;;
    --email)    EMAIL="$2"; shift 2;;
    --cert-file) CERT_FILE="$2"; shift 2;;
    --key-file)  KEY_FILE="$2"; shift 2;;
    --dry-run)  DRYRUN=1; shift;;
    --yes)      YES=1; shift;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1";;
  esac
done

# ── dry-run-aware executors ─────────────────────────────────────────────
run() {
  if (( DRYRUN )); then printf "   %s[dry-run]%s would run: %s\n" "$C_Y" "$C_0" "$*";
  else "$@"; fi
}
write_conf() {  # write_conf <path> <<<content
  local path="$1" content; content="$(cat)"
  if (( DRYRUN )); then
    printf "\n   %s[dry-run]%s would write %s%s%s:\n" "$C_Y" "$C_0" "$C_B" "$path" "$C_0"
    printf "%s\n" "$content" | sed 's/^/     │ /'
  else
    printf "%s\n" "$content" | sudo tee "$path" >/dev/null
    say "wrote $path"
  fi
}
ask() {  # ask <varname> <prompt> [default]
  local var="$1" prompt="$2" def="${3:-}" cur="${!1:-}" ans
  [[ -n "$cur" ]] && return 0
  if (( YES )); then [[ -n "$def" ]] && { printf -v "$var" '%s' "$def"; return 0; } || die "--yes given but $var is unset"; fi
  read -r -p "$(printf '%s?%s %s%s: ' "$C_B" "$C_0" "$prompt" "${def:+ [$def]}")" ans
  printf -v "$var" '%s' "${ans:-$def}"
}

# ── detect distro (for package + service names) ─────────────────────────
OSID="unknown"; [[ -r /etc/os-release ]] && OSID="$(. /etc/os-release; echo "${ID_LIKE:-$ID}")"
apache_svc="httpd"; apache_pkg="httpd mod_ssl"; nginx_pkg="nginx"; certbot_hint=""
case "$OSID" in
  *debian*|*ubuntu*) apache_svc="apache2"; apache_pkg="apache2"; certbot_hint="sudo apt install certbot python3-certbot-nginx python3-certbot-apache";;
  *suse*)            apache_svc="apache2"; apache_pkg="apache2"; certbot_hint="sudo zypper install certbot python3-certbot-nginx python3-certbot-apache";;
  *rhel*|*fedora*|*centos*) certbot_hint="sudo dnf install certbot python3-certbot-nginx python3-certbot-apache";;
  *) certbot_hint="install certbot + the nginx/apache plugin for your distro";;
esac

# ── gather inputs ───────────────────────────────────────────────────────
say "Breeze Core reverse-proxy wizard${DRYRUN:+ (dry run — no changes)}"
ask SERVER "Web server (nginx/apache)" "nginx"
[[ "$SERVER" =~ ^(nginx|apache)$ ]] || die "server must be nginx or apache"
ask DOMAIN "Public domain (e.g. breeze.example.com)"
[[ -n "$DOMAIN" ]] || die "a domain is required"
ask UPSTREAM "Breeze Core upstream host:port" "$UPSTREAM"
ask LAN "LAN/VPN CIDRs allowed to approve pairings (comma-separated)" "$LAN"
ask CERT "TLS: certbot / existing / none" "$CERT"
[[ "$CERT" =~ ^(certbot|existing|none)$ ]] || die "cert must be certbot, existing or none"
[[ "$CERT" == certbot  ]] && ask EMAIL "Email for Let's Encrypt (blank = --register-unsafely-without-email)" ""
if [[ "$CERT" == existing ]]; then
  ask CERT_FILE "Path to fullchain cert" ""
  ask KEY_FILE  "Path to private key" ""
  [[ -n "$CERT_FILE" && -n "$KEY_FILE" ]] || die "--cert existing needs --cert-file and --key-file"
fi

CERTBOT_EMAIL=()
[[ "$CERT" == certbot && -n "$EMAIL" ]] && CERTBOT_EMAIL=(-m "$EMAIL")
[[ "$CERT" == certbot && -z "$EMAIL" ]] && CERTBOT_EMAIL=(--register-unsafely-without-email)

UP_HOST="${UPSTREAM%%:*}"; UP_PORT="${UPSTREAM##*:}"
# turn "a,b" into nginx "allow a; allow b;" / apache "Require ip a b"
IFS=',' read -ra LANS <<< "$LAN"
NGX_ALLOW=""; for c in "${LANS[@]}"; do NGX_ALLOW+="allow ${c// /}; "; done
APA_REQUIRE="${LAN//,/ }"

echo; say "Plan"
cat <<PLAN
   server     : $SERVER  (service: $([[ $SERVER == apache ]] && echo "$apache_svc" || echo nginx))
   domain     : $DOMAIN
   upstream   : http://$UP_HOST:$UP_PORT
   admin CIDRs: $LAN
   TLS        : $CERT${EMAIL:+  (email $EMAIL)}
PLAN

# ── generate + install ──────────────────────────────────────────────────
if [[ "$SERVER" == nginx ]]; then
  case "$OSID" in *debian*|*ubuntu*) CONF="/etc/nginx/sites-available/${DOMAIN}.conf";; *) CONF="/etc/nginx/conf.d/${DOMAIN}.conf";; esac
  if [[ "$CERT" == existing ]]; then LISTEN="listen 443 ssl; listen [::]:443 ssl; http2 on;"; SSL="ssl_certificate $CERT_FILE;\n    ssl_certificate_key $KEY_FILE;\n    ssl_protocols TLSv1.2 TLSv1.3;"; else LISTEN="listen 80; listen [::]:80;"; SSL="# TLS added by certbot"; fi
  write_conf "$CONF" <<NGINX
limit_req_zone  \$binary_remote_addr zone=bz_api:10m  rate=10r/s;
limit_req_zone  \$binary_remote_addr zone=bz_auth:10m rate=2r/s;

server {
    $LISTEN
    server_name $DOMAIN;
    $(printf '%b' "$SSL")

    server_tokens off;
    client_max_body_size 16k;
    limit_req_status 429;
    access_log /var/log/nginx/${DOMAIN}.access.log;

    proxy_set_header Host              \$host;
    proxy_set_header X-Forwarded-For   \$remote_addr;      # overwrite (anti-spoof)
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 20s;

    location = /api/auth/enroll/approve { ${NGX_ALLOW}deny all; limit_req zone=bz_auth burst=5 nodelay; proxy_pass http://$UP_HOST:$UP_PORT; }
    location ^~ /api/auth/devices       { ${NGX_ALLOW}deny all; limit_req zone=bz_auth burst=5 nodelay; proxy_pass http://$UP_HOST:$UP_PORT; }
    location ^~ /api/auth/              { limit_req zone=bz_auth burst=8 nodelay; proxy_pass http://$UP_HOST:$UP_PORT; }
    location /                          { limit_req zone=bz_api  burst=25 nodelay; proxy_pass http://$UP_HOST:$UP_PORT; }
}
NGINX
  case "$OSID" in *debian*|*ubuntu*) run sudo ln -sf "$CONF" "/etc/nginx/sites-enabled/${DOMAIN}.conf";; esac
  run sudo nginx -t
  run sudo systemctl reload nginx
  if [[ "$CERT" == certbot ]]; then
    run sudo certbot --nginx -d "$DOMAIN" --redirect -n --agree-tos "${CERTBOT_EMAIL[@]}"
  fi
else
  case "$OSID" in *debian*|*ubuntu*) CONF="/etc/apache2/sites-available/${DOMAIN}.conf";; *) CONF="/etc/httpd/conf.d/${DOMAIN}.conf";; esac
  if [[ "$CERT" == existing ]]; then VH_PORT=443; SSL="SSLEngine on\n    SSLCertificateFile $CERT_FILE\n    SSLCertificateKeyFile $KEY_FILE\n    SSLProtocol -all +TLSv1.2 +TLSv1.3"; PROTO=https; else VH_PORT=80; SSL="# TLS added by certbot"; PROTO=http; fi
  write_conf "$CONF" <<APACHE
<VirtualHost *:$VH_PORT>
    ServerName $DOMAIN
    $(printf '%b' "$SSL")

    ServerTokens Prod
    LimitRequestBody 16384
    ProxyPreserveHost On
    ProxyTimeout 20
    RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}s"
    RequestHeader set X-Forwarded-Proto "$PROTO"
    CustomLog /var/log/${apache_svc}/${DOMAIN}.access.log combined

    <LocationMatch "^/api/auth/(enroll/approve|devices)">
        Require ip $APA_REQUIRE
    </LocationMatch>

    ProxyPass        / http://$UP_HOST:$UP_PORT/
    ProxyPassReverse / http://$UP_HOST:$UP_PORT/
</VirtualHost>
APACHE
  case "$OSID" in *debian*|*ubuntu*) run sudo a2enmod proxy proxy_http ssl headers rewrite remoteip; run sudo a2ensite "${DOMAIN}.conf";; esac
  run sudo "$apache_svc" -t 2>/dev/null || run sudo apachectl configtest
  run sudo systemctl reload "$apache_svc"
  if [[ "$CERT" == certbot ]]; then
    run sudo certbot --apache -d "$DOMAIN" --redirect -n --agree-tos "${CERTBOT_EMAIL[@]}"
  fi
fi

[[ "$CERT" == none ]] && warn "TLS was skipped — this is HTTP only. Do not use over the internet."
[[ -z "$certbot_hint" ]] || [[ "$CERT" != certbot ]] || command -v certbot >/dev/null 2>&1 || warn "certbot not found — install it first: $certbot_hint"

echo; say "Next: point Breeze Core at loopback and trust the proxy"
cat <<NEXT
   In the Breeze Core systemd unit (or compose environment), set:
     AC_BEHIND_PROXY=1
     AC_TRUSTED_HOSTS=$DOMAIN,127.0.0.1
     AC_ENROLL_LAN_ONLY=1
   and bind uvicorn to $UP_HOST ( --proxy-headers --forwarded-allow-ips 127.0.0.1 ),
   then restart it. Open 80/443 in your firewall and close direct $UP_PORT.
   Review HARDENING.md, and add the fail2ban jails watching
   /var/log/${SERVER/apache/$apache_svc}/${DOMAIN}.access.log.
NEXT
(( DRYRUN )) && { echo; say "dry run complete — nothing was changed."; }
