[← Breeze Core](../README.md)

# Exposing Breeze Core beyond the LAN

By default Breeze Core is LAN-only. To reach it from outside your network you put a **reverse proxy** in front that terminates **TLS**, and you keep the app bound to loopback so the proxy is the only way in.

**Contents:**
[0. Prerequisites](#0-prerequisites) ·
[1. Loopback + proxy trust](#1-re-point-the-app-at-loopback--trust-the-proxy) ·
[2. Reverse proxy (nginx / Apache)](#2-reverse-proxy) ·
[3. TLS certificate (certbot / acme.sh)](#3-tls-certificate) ·
[4. Verify](#4-verify) ·
[5. Next](#5-next)

> A VPN (WireGuard/Tailscale) avoids public exposure altogether and is worth considering; otherwise read this alongside [HARDENING.md](../HARDENING.md).

This guide covers **nginx** and **Apache** separately, and certificates via **certbot** and **acme.sh**. Pick one web server and one ACME client.

> **On Windows?** Use the guided **Caddy** wizard instead (automatic HTTPS, same hardening — HSTS/headers, LAN-only admin gate, real-client XFF, plus a fail2ban-style IP banner). See [docs/WINDOWS.md sec. 5](WINDOWS.md#5-expose-it-publicly-with-caddy). Caddy also works on Linux/macOS if you prefer it to nginx/Apache.

> **Want it done for you?** [`deploy/reverse-proxy-wizard.sh`](../deploy/reverse-proxy-wizard.sh) generates and installs a hardened nginx *or* Apache vhost (LAN-gated admin endpoints, anti-spoof XFF, rate limiting) and can obtain a certbot cert. Run it with **`--dry-run`** first to preview every file and command it would touch, changing nothing:
> ```bash
> ./deploy/reverse-proxy-wizard.sh --server nginx --domain breeze.example.com --cert certbot --email you@example.com --dry-run
> ```
> The manual steps below are the reference for what it produces (and for acme.sh, which the wizard defers to via `--cert existing`).

---

## 0. Prerequisites

- A **domain name** (e.g. `breeze.example.com`) with a DNS **A/AAAA record** pointing at your public IP.
- Ports **80** and **443** reachable from the internet (router port-forward / firewall).
- Breeze Core already installed and working on the LAN ([INSTALL.md](INSTALL.md)).

---

## 1. Re-point the app at loopback + trust the proxy

Edit `/etc/systemd/system/breeze-core.service`: bind `127.0.0.1`, trust forwarded headers **only** from the local proxy, and pin the hostname. This is what makes the LAN-only admin check correct behind a proxy (the real client IP arrives via `X-Forwarded-For`).

```ini
Environment=AC_BEHIND_PROXY=1
Environment=AC_TRUSTED_HOSTS=breeze.example.com,127.0.0.1,localhost
Environment=AC_ENROLL_LAN_ONLY=1
ExecStart=/opt/breeze-core/venv/bin/uvicorn meow_ac.app:app \
  --host 127.0.0.1 --port 8420 --proxy-headers --forwarded-allow-ips 127.0.0.1
```
```bash
sudo systemctl daemon-reload && sudo systemctl restart breeze-core
```

Then **close 8420 to the LAN** (the proxy reaches it on loopback) and **open 80/443**:
```bash
# firewalld:
sudo firewall-cmd --permanent --zone=internal --remove-port=8420/tcp
sudo firewall-cmd --permanent --add-service=http --add-service=https
sudo firewall-cmd --reload
# ufw:
sudo ufw delete allow 8420/tcp 2>/dev/null; sudo ufw allow 80,443/tcp
```

---

## 2. Reverse proxy

Install your web server, drop in the config, then get a certificate (section 3).

### Option A — nginx

**Install:** `sudo dnf install -y nginx` (RHEL/Fedora/SUSE use `nginx`; SUSE via `zypper`) · `sudo apt install -y nginx` (Debian/Ubuntu). Then `sudo systemctl enable --now nginx`.

Create `/etc/nginx/conf.d/breeze.conf` (Debian/Ubuntu: `/etc/nginx/sites-available/breeze.conf` + symlink into `sites-enabled/`). Start with **HTTP only** so certbot can validate; section 3 adds TLS.

```nginx
# rate-limit zones (http{} context)
limit_req_zone  $binary_remote_addr zone=bz_api:10m  rate=10r/s;
limit_req_zone  $binary_remote_addr zone=bz_auth:10m rate=2r/s;

server {
    listen 80;
    listen [::]:80;
    server_name breeze.example.com;

    server_tokens off;
    client_max_body_size 16k;              # control payloads are tiny
    limit_req_status 429;

    # SECURITY: overwrite X-Forwarded-For with the real peer. Using
    # $proxy_add_x_forwarded_for would let a client spoof a LAN IP and
    # bypass the app's LAN-only admin check. Do not change this.
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-For   $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 20s;

    # Admin endpoints: only reachable from the LAN (defense-in-depth;
    # the app enforces this too). Adjust the CIDR to your network.
    location = /api/auth/enroll/approve { allow 192.168.0.0/16; allow 127.0.0.1; deny all; limit_req zone=bz_auth burst=5 nodelay; proxy_pass http://127.0.0.1:8420; }
    location ^~ /api/auth/devices       { allow 192.168.0.0/16; allow 127.0.0.1; deny all; limit_req zone=bz_auth burst=5 nodelay; proxy_pass http://127.0.0.1:8420; }
    location ^~ /api/auth/              { limit_req zone=bz_auth burst=8 nodelay; proxy_pass http://127.0.0.1:8420; }
    location /                          { limit_req zone=bz_api  burst=25 nodelay; proxy_pass http://127.0.0.1:8420; }
}
```
```bash
sudo nginx -t && sudo systemctl reload nginx
```
After you obtain a cert (section 3) certbot rewrites this to `listen 443 ssl;` and adds a port-80 → 443 redirect automatically.

> **Live updates (SSE).** The app's live-state stream (`GET /api/units/stream`, Breeze Core ≥ 3.0.0) is a long-lived `text/event-stream`. The app sends `X-Accel-Buffering: no` on the response, which **nginx honours automatically** — no config change needed; the config above already proxies it. If you front it with **Apache**, disable output buffering for that path (`SetEnv proxy-sendchunked 1` and avoid `mod_deflate` on it), and with **Caddy** it works out of the box. The stream also self-disables compression (`Content-Encoding: identity`), so no proxy needs to touch it.

### Option B — Apache (httpd)

**Install + modules:**
```bash
# RHEL/Fedora/SUSE:
sudo dnf install -y httpd mod_ssl        # (SUSE: sudo zypper install apache2 apache2-mod_...)
# Debian/Ubuntu:
sudo apt install -y apache2
sudo a2enmod proxy proxy_http ssl headers rewrite remoteip
```
On RHEL the modules ship enabled in `/etc/httpd/conf.modules.d/`. The service is `httpd` (RHEL/SUSE) or `apache2` (Debian).

Create the vhost — `/etc/httpd/conf.d/breeze.conf` (RHEL/SUSE) or `/etc/apache2/sites-available/breeze.conf` + `sudo a2ensite breeze` (Debian). HTTP-only first:

```apache
<VirtualHost *:80>
    ServerName breeze.example.com

    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:8420/
    ProxyPassReverse / http://127.0.0.1:8420/
    ProxyTimeout 20

    ServerTokens Prod
    LimitRequestBody 16384

    # SECURITY: overwrite X-Forwarded-For with the real client so a
    # spoofed header can't pose as a LAN address (mod_headers).
    RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}s"
    RequestHeader set X-Forwarded-Proto "http"

    # Admin endpoints: LAN only (defense-in-depth). Adjust the CIDR.
    <LocationMatch "^/api/auth/(enroll/approve|devices)">
        Require ip 192.168.0.0/16 127.0.0.1
    </LocationMatch>
</VirtualHost>
```
```bash
# RHEL/SUSE:  sudo systemctl enable --now httpd && sudo apachectl configtest && sudo systemctl reload httpd
# Debian:     sudo systemctl enable --now apache2 && sudo apache2ctl configtest && sudo systemctl reload apache2
```
Rate limiting on Apache isn't built into core; add `mod_ratelimit` (bandwidth) or, for request throttling, `mod_qos` or `mod_evasive` — or rely on fail2ban (see HARDENING.md). Set `X-Forwarded-Proto "https"` in the SSL vhost that certbot creates.

---

## 3. TLS certificate

Use **one** ACME client. Both get free, auto-renewing certs from Let's Encrypt.

### Option 1 — certbot (integrates with the web server)

**Install:**
```bash
# RHEL/Fedora:   sudo dnf install -y certbot python3-certbot-nginx    # or python3-certbot-apache
# Debian/Ubuntu: sudo apt install -y certbot python3-certbot-nginx    # or python3-certbot-apache
# openSUSE:      sudo zypper install -y certbot python3-certbot-nginx # or -apache
# any distro:    sudo python3 -m venv /opt/certbot && /opt/certbot/bin/pip install certbot certbot-nginx
```

**Obtain + install the cert** (edits your vhost to add TLS + the redirect):
```bash
# nginx:
sudo certbot --nginx -d breeze.example.com
# Apache:
sudo certbot --apache -d breeze.example.com
```
No plugin (e.g. behind a different setup)? Use webroot or standalone:
```bash
sudo certbot certonly --webroot -w /var/www/html -d breeze.example.com
# then reference /etc/letsencrypt/live/breeze.example.com/{fullchain,privkey}.pem in your vhost
```

**Auto-renewal** is installed as a systemd timer (or cron) automatically:
```bash
systemctl list-timers | grep certbot        # confirm it's scheduled
sudo certbot renew --dry-run                 # test; renewal reloads the web server
```

### Option 2 — acme.sh (no Python, tiny, shell-only)

```bash
curl https://get.acme.sh | sh -s email=you@example.com
export PATH="$HOME/.acme.sh:$PATH"

# issue (webroot; make sure the HTTP vhost serves /.well-known/acme-challenge/):
acme.sh --issue -d breeze.example.com -w /var/www/html
# or use the built-in standalone server on :80 (stop the web server first): add --standalone

# install the cert and tell acme.sh how to reload your web server:
acme.sh --install-cert -d breeze.example.com \
  --key-file       /etc/ssl/breeze/privkey.pem \
  --fullchain-file /etc/ssl/breeze/fullchain.pem \
  --reloadcmd      "systemctl reload nginx"     # or 'systemctl reload httpd|apache2'
```
Then point your vhost's `ssl_certificate` / `SSLCertificateFile` at those files. acme.sh installs its own cron for renewal.

**TLS vhost snippets** (after you have a cert) — nginx:
```nginx
listen 443 ssl;  http2 on;
ssl_certificate     /etc/letsencrypt/live/breeze.example.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/breeze.example.com/privkey.pem;
ssl_protocols TLSv1.2 TLSv1.3;
```
Apache:
```apache
<VirtualHost *:443>
    ServerName breeze.example.com
    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/breeze.example.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/breeze.example.com/privkey.pem
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    # ... same ProxyPass / headers / LocationMatch as the port-80 vhost,
    #     plus: RequestHeader set X-Forwarded-Proto "https"
</VirtualHost>
# redirect 80 → 443 in the port-80 vhost: Redirect permanent / https://breeze.example.com/
```

---

## 4. Verify

```bash
DOM=breeze.example.com
curl -s -o /dev/null -w 'redirect: %{http_code}\n' http://$DOM/            # 301
curl -s -o /dev/null -w 'ui: %{http_code}\n'       https://$DOM/            # 200
curl -s -o /dev/null -w 'api: %{http_code}\n'      https://$DOM/api/units   # 401 (needs key+token)
curl -s -o /dev/null -w 'docs: %{http_code}\n'     https://$DOM/openapi.json# 404 (disabled)
curl -sI https://$DOM/api/units | grep -iE 'strict-transport|content-security|x-frame'  # present
```
The app emits security headers itself (`AC_SECURITY_HEADERS=1`, default). If you'd rather set them in the proxy, set `AC_SECURITY_HEADERS=0` and add them there instead — don't do both.

---

## 5. Next

Public exposure means bots *will* find the hostname (it appears in Certificate Transparency logs). Set up **fail2ban** and review the full checklist in **[HARDENING.md](../HARDENING.md)** before you rely on this.
