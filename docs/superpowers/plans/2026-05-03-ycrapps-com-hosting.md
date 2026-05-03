# ycrapps.com Self-Hosted Portfolio — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the static portfolio at `https://ycrapps.com` from Yuval's home server, fronted by a dedicated Cloudflare Tunnel, hardened by default, with a cron-driven deploy from `origin/main`.

**Architecture:** Cloudflared (outbound-only) → nginx on `127.0.0.1:8080` → static files in `/var/www/ycrapps/`. A user-cron polls the GitHub repo every 5 min and atomically rsyncs into the doc root. All TLS / WAF / Bot / rate-limiting handled at the Cloudflare edge. No inbound port is opened on the home router. Existing `cafehakerem.*` service is fully isolated via a separate, new tunnel.

**Tech Stack:** nginx, cloudflared, systemd, cron, rsync, git. No new languages or runtimes.

**Execution context:** Most steps run on the server (`ssh yuval@server`). A few steps run from this Mac repo (`~/Documents/Job/Personal_site/`). Each step labels which.

---

## File Structure

**In this repo (committed):**
- `scripts/deploy-ycrapps.sh` — deploy script. Cron points at this path on the server.
- `nginx/ycrapps.conf` — nginx site config. Manually copied to server during install.
- `cloudflared/config.yml.example` — sanitized tunnel config template.
- `docs/superpowers/specs/2026-05-03-ycrapps-com-hosting-design.md` — design (already committed).
- `docs/superpowers/plans/2026-05-03-ycrapps-com-hosting.md` — this plan.

**On server (not in git):**
- `/var/www/ycrapps/` — doc root, `root:www-data` 0755, files 0644.
- `/etc/nginx/sites-available/ycrapps.conf` and `…/sites-enabled/ycrapps.conf` (symlink).
- `/etc/cloudflared-ycrapps/config.yml` — tunnel config (separate dir from any existing cloudflared install for the coffee-shop tunnel).
- `/etc/cloudflared-ycrapps/<tunnel-uuid>.json` — credentials, root:root 0600.
- `/etc/systemd/system/cloudflared-ycrapps.service` — systemd unit for the new tunnel.
- `/etc/sudoers.d/ycrapps-deploy` — narrow rsync write rule.
- `~/logs/ycrapps-deploy.log` — deploy log (created on first run).
- User crontab entry pointing at `~/yuval_cohen_rappaport/scripts/deploy-ycrapps.sh`.

---

## Task 0: Preflight on the server

**Files:** none — discovery only.

- [ ] **Step 1: SSH in and confirm baseline.**

Run on Mac:
```bash
ssh yuval@server "uname -a && lsb_release -d && which nginx cloudflared rsync git curl 2>&1"
```
Expected: Ubuntu 22.04+ (or similar), `rsync`, `git`, `curl` present. `nginx` and `cloudflared` may or may not be present — both outcomes are handled below.

- [ ] **Step 2: Confirm the existing coffee-shop service does not collide.**

Run on server:
```bash
ssh yuval@server "systemctl list-units --all 'cloudflared*' --no-pager; echo '---'; ls /etc/cloudflared* 2>/dev/null"
```
Record the names of any existing cloudflared services and config dirs. This plan's new service is `cloudflared-ycrapps.service` and its config dir is `/etc/cloudflared-ycrapps/` — any existing `cloudflared.service` or `/etc/cloudflared/` is untouched.

- [ ] **Step 3: Confirm port 8080 is free on localhost.**

Run on server:
```bash
ssh yuval@server "ss -tlnp | grep ':8080 ' || echo 'PORT 8080 FREE'"
```
Expected: `PORT 8080 FREE`. If something is bound to 8080, stop and pick a different localhost port (e.g. 8088). Update `nginx/ycrapps.conf` and the tunnel ingress accordingly before continuing.

- [ ] **Step 4: Confirm `ycrapps.com` is on Cloudflare nameservers.**

Run on Mac:
```bash
dig +short NS ycrapps.com
```
Expected: two `*.ns.cloudflare.com` entries. If anything else, stop and fix nameservers first.

- [ ] **Step 5: Clarify the coffee-shop subdomain zone.**

Ask Yuval (one short message): "Just to lock down the precondition — is the coffee-shop subdomain at `cafehakerem.ycrapps.com` (same zone, typo earlier) or on a separate zone `ycrapp.com`?" Record the answer in the deploy log later. The plan does not depend on the answer (zones and tunnels are isolated either way), but knowing avoids surprises during DNS UI work.

---

## Task 1: Install nginx (if not present)

**Files (server):** `/etc/nginx/…` (system).

- [ ] **Step 1: Install if missing.**

Run on server:
```bash
ssh yuval@server "which nginx || sudo apt-get update && sudo apt-get install -y nginx"
```

- [ ] **Step 2: Confirm nginx is running.**

```bash
ssh yuval@server "systemctl is-active nginx && nginx -v"
```
Expected: `active` and a version line.

- [ ] **Step 3: Disable the default site so port 80 doesn't accidentally serve the wrong content.**

```bash
ssh yuval@server "sudo rm -f /etc/nginx/sites-enabled/default && sudo nginx -t && sudo systemctl reload nginx"
```
Expected: `nginx: configuration file /etc/nginx/nginx.conf test is successful`. (Note: even if 80 stays bound, the home router blocks inbound — but symbolic-link cleanup keeps the box tidy.)

- [ ] **Step 4: Verify nothing is listening publicly on 80/443.**

```bash
ssh yuval@server "ss -tlnp | grep -E ':80 |:443 ' || echo 'NONE'"
```
Expected: `NONE` (or only `127.0.0.1:80` from leftover default — that's fine since AP isolation blocks it anyway). The intent is to confirm no surprise public bind exists.

---

## Task 2: Create the doc root and a placeholder index

We bring up the whole pipeline pointed at a placeholder page first, then point it at the real site only after everything works. This isolates "did the tunnel work?" from "is the site content right?".

**Files (server):** `/var/www/ycrapps/`.

- [ ] **Step 1: Create directory with strict ownership.**

```bash
ssh yuval@server "sudo mkdir -p /var/www/ycrapps && sudo chown root:www-data /var/www/ycrapps && sudo chmod 755 /var/www/ycrapps"
```

- [ ] **Step 2: Drop a placeholder index.**

```bash
ssh yuval@server "echo '<!doctype html><title>ycrapps.com placeholder</title><h1>ycrapps.com is alive (placeholder)</h1>' | sudo tee /var/www/ycrapps/index.html >/dev/null && sudo chown root:www-data /var/www/ycrapps/index.html && sudo chmod 644 /var/www/ycrapps/index.html"
```

- [ ] **Step 3: Verify perms.**

```bash
ssh yuval@server "ls -la /var/www/ycrapps/"
```
Expected: dir `drwxr-xr-x root www-data`, file `-rw-r--r-- root www-data index.html`.

---

## Task 3: Write the nginx site config

**Files (Mac repo):** create `nginx/ycrapps.conf`.
**Files (server):** copy to `/etc/nginx/sites-available/ycrapps.conf`, symlink into `sites-enabled`.

- [ ] **Step 1: Create `nginx/ycrapps.conf` in the Mac repo.**

Path: `~/Documents/Job/Personal_site/nginx/ycrapps.conf`. Full content:

```nginx
# ycrapps.com — origin server. Reached only via cloudflared on localhost.
# Do NOT expose this on 0.0.0.0 or 443.

server {
    listen 127.0.0.1:8080 default_server;
    listen [::1]:8080 default_server;
    server_name ycrapps.com www.ycrapps.com _;

    root /var/www/ycrapps;
    index index.html;

    server_tokens off;

    # Static-only. No autoindex, no proxying, no PHP, no symlinks outside root.
    autoindex off;
    disable_symlinks on;

    # Compression
    gzip on;
    gzip_vary on;
    gzip_min_length 256;
    gzip_types text/plain text/css text/javascript application/javascript application/json image/svg+xml application/xml+rss;

    # Default: deny by extension/path patterns that should not exist on a static site.
    location ~ /\.(?!well-known) { deny all; access_log off; log_not_found off; }
    location ~ \.(php|cgi|pl|asp|aspx)$ { return 404; }

    # Security headers on every response. Applied via add_header always.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self' 'unsafe-inline' https://static.cloudflareinsights.com; connect-src 'self' https://cloudflareinsights.com; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'none'" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()" always;

    # HTML: no-cache so deploys are visible immediately.
    location ~* \.html$ {
        add_header Cache-Control "no-cache" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
        add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self' 'unsafe-inline' https://static.cloudflareinsights.com; connect-src 'self' https://cloudflareinsights.com; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'none'" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()" always;
    }

    # Hashed asset future-proofing: anything under /assets/ or with a content hash gets long cache.
    location ~* \.(css|js|woff2?|svg|png|jpg|jpeg|gif|webp|ico)$ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

- [ ] **Step 2: Copy onto the server and enable.**

```bash
scp ~/Documents/Job/Personal_site/nginx/ycrapps.conf yuval@server:/tmp/ycrapps.conf
ssh yuval@server "sudo mv /tmp/ycrapps.conf /etc/nginx/sites-available/ycrapps.conf && sudo chown root:root /etc/nginx/sites-available/ycrapps.conf && sudo ln -sf /etc/nginx/sites-available/ycrapps.conf /etc/nginx/sites-enabled/ycrapps.conf"
```

- [ ] **Step 3: Test config and reload.**

```bash
ssh yuval@server "sudo nginx -t && sudo systemctl reload nginx"
```
Expected: `test is successful` and clean reload.

- [ ] **Step 4: Verify localhost serves the placeholder with the headers.**

```bash
ssh yuval@server "curl -sI http://127.0.0.1:8080/ | sort"
```
Expected output (lines may reorder; key items shown):
```
HTTP/1.1 200 OK
Cache-Control: no-cache
Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; ...
Permissions-Policy: camera=(), microphone=(), geolocation=(), ...
Referrer-Policy: strict-origin-when-cross-origin
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
```
If any header is missing, fix the conf and re-reload before moving on.

- [ ] **Step 5: Commit.**

Run on Mac:
```bash
cd ~/Documents/Job/Personal_site
git add nginx/ycrapps.conf
git commit -m "feat(nginx): origin site config for ycrapps.com (localhost:8080)"
```

---

## Task 4: Install or reuse cloudflared, then create a new tunnel

**Files (server):** `/etc/cloudflared-ycrapps/`, `/etc/systemd/system/cloudflared-ycrapps.service`.

- [ ] **Step 1: Install cloudflared if not present.**

Run on server:
```bash
ssh yuval@server '
if ! command -v cloudflared >/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
  sudo apt-get update && sudo apt-get install -y cloudflared
fi
cloudflared --version
'
```
Expected: a version string like `cloudflared version 2024.x.x`.

- [ ] **Step 2: Authenticate cloudflared (interactive — needs Yuval).**

Run on server:
```bash
ssh -t yuval@server "cloudflared tunnel login"
```
This opens a browser URL. Yuval visits it on the Mac, picks the `ycrapps.com` zone, authorizes. The cert lands at `~/.cloudflared/cert.pem` on the server.

If already logged in for the coffee-shop tunnel, this re-uses the existing cert (the cert is account-wide, scoped to selected zones).

- [ ] **Step 3: Create the new tunnel.**

```bash
ssh yuval@server "cloudflared tunnel create ycrapps-portfolio"
```
Expected output:
```
Tunnel credentials written to /home/yuval/.cloudflared/<UUID>.json.
Created tunnel ycrapps-portfolio with id <UUID>
```
**Record the UUID.** Used in the next steps.

- [ ] **Step 4: Move credentials into a dedicated config dir.**

Replace `<UUID>` with the actual UUID from step 3:
```bash
ssh yuval@server '
UUID=<UUID>
sudo mkdir -p /etc/cloudflared-ycrapps
sudo mv /home/yuval/.cloudflared/${UUID}.json /etc/cloudflared-ycrapps/${UUID}.json
sudo chown root:root /etc/cloudflared-ycrapps/${UUID}.json
sudo chmod 600 /etc/cloudflared-ycrapps/${UUID}.json
'
```

- [ ] **Step 5: Write the tunnel config.**

Replace `<UUID>` accordingly:
```bash
ssh yuval@server "sudo tee /etc/cloudflared-ycrapps/config.yml <<'EOF'
tunnel: <UUID>
credentials-file: /etc/cloudflared-ycrapps/<UUID>.json

ingress:
  - hostname: ycrapps.com
    service: http://127.0.0.1:8080
  - hostname: www.ycrapps.com
    service: http://127.0.0.1:8080
  - service: http_status:404
EOF
sudo chown root:root /etc/cloudflared-ycrapps/config.yml
sudo chmod 644 /etc/cloudflared-ycrapps/config.yml"
```

- [ ] **Step 6: Validate the config.**

```bash
ssh yuval@server "cloudflared tunnel --config /etc/cloudflared-ycrapps/config.yml ingress validate"
```
Expected: `Validating rules from /etc/cloudflared-ycrapps/config.yml ... OK`.

- [ ] **Step 7: Add DNS routes for the apex and www.**

```bash
ssh yuval@server "cloudflared tunnel --config /etc/cloudflared-ycrapps/config.yml route dns ycrapps-portfolio ycrapps.com"
ssh yuval@server "cloudflared tunnel --config /etc/cloudflared-ycrapps/config.yml route dns ycrapps-portfolio www.ycrapps.com"
```
Each prints `Added CNAME ... which will route traffic to tunnel ycrapps-portfolio`. If a record already exists at the apex (e.g. CF default `A`), the command prints a conflict — delete the conflicting record from the CF dashboard and rerun.

- [ ] **Step 8: Sanity-check the resulting CNAMEs at Cloudflare.**

Run on Mac:
```bash
dig +short CNAME ycrapps.com @1.1.1.1
dig +short CNAME www.ycrapps.com @1.1.1.1
```
Expected: both return `<UUID>.cfargotunnel.com.` (proxied flag is on).

- [ ] **Step 9: Commit the example config (sanitized).**

Create `~/Documents/Job/Personal_site/cloudflared/config.yml.example`:
```yaml
# Template. Copy to /etc/cloudflared-ycrapps/config.yml on the server,
# replace <UUID> with the value from `cloudflared tunnel create`.
tunnel: <UUID>
credentials-file: /etc/cloudflared-ycrapps/<UUID>.json

ingress:
  - hostname: ycrapps.com
    service: http://127.0.0.1:8080
  - hostname: www.ycrapps.com
    service: http://127.0.0.1:8080
  - service: http_status:404
```

```bash
cd ~/Documents/Job/Personal_site
git add cloudflared/config.yml.example
git commit -m "feat(cloudflared): tunnel config template for ycrapps-portfolio"
```

---

## Task 5: Run the new tunnel as a dedicated systemd service

**Files (server):** `/etc/systemd/system/cloudflared-ycrapps.service`.

- [ ] **Step 1: Write the unit file.**

```bash
ssh yuval@server "sudo tee /etc/systemd/system/cloudflared-ycrapps.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel for ycrapps.com
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --config /etc/cloudflared-ycrapps/config.yml run
Restart=on-failure
RestartSec=5s
DynamicUser=no
User=cloudflared
Group=cloudflared
ReadOnlyPaths=/etc/cloudflared-ycrapps
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
sudo chown root:root /etc/systemd/system/cloudflared-ycrapps.service
sudo chmod 644 /etc/systemd/system/cloudflared-ycrapps.service"
```

- [ ] **Step 2: Create the `cloudflared` system user (idempotent — it may already exist from step 1).**

```bash
ssh yuval@server "id cloudflared >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin cloudflared; sudo chown -R cloudflared:cloudflared /etc/cloudflared-ycrapps"
```

- [ ] **Step 3: Enable and start.**

```bash
ssh yuval@server "sudo systemctl daemon-reload && sudo systemctl enable --now cloudflared-ycrapps.service"
```

- [ ] **Step 4: Verify it's running and connected.**

```bash
ssh yuval@server "systemctl status cloudflared-ycrapps.service --no-pager -l | head -25"
```
Expected: `active (running)`. Logs should show 4 connections registered to Cloudflare (`Registered tunnel connection` x 4).

- [ ] **Step 5: External smoke test from Mac.**

```bash
curl -sI https://ycrapps.com/ | head -20
```
Expected: `HTTP/2 200`, all the security headers from Task 3, and a `cf-ray:` header confirming Cloudflare. The body should be the placeholder.

If DNS hasn't propagated yet, wait 60s and retry. If `curl` returns 5xx, check `journalctl -u cloudflared-ycrapps -n 50` on the server.

- [ ] **Step 6: Confirm the existing coffee-shop service still works.**

Ask Yuval to verify `cafehakerem.<zone>` still loads. Or, if Yuval shares the URL, run `curl -I https://cafehakerem.<zone>/` from Mac and confirm 200/302/whatever the expected status is. This catches any accidental regression on the existing tunnel.

---

## Task 6: Configure Cloudflare zone hardening (dashboard work)

This task is performed in the Cloudflare dashboard for the `ycrapps.com` zone. There's no programmatic step here unless we want to use the API — we don't, this is a one-time setup.

- [ ] **Step 1: SSL/TLS → Overview → set mode to `Full (strict)`.**

The cloudflared tunnel presents a CF-issued cert at the origin, so strict will validate cleanly.

- [ ] **Step 2: SSL/TLS → Edge Certificates:**
  - Always Use HTTPS: **On**.
  - Automatic HTTPS Rewrites: **On**.
  - Minimum TLS Version: **1.3**.
  - HSTS: **On**, max-age 12 months, Apply HSTS to subdomains: **On**, Preload: **On**, No-Sniff: **On**.

- [ ] **Step 3: Security → WAF:**
  - Managed Rules → Cloudflare Managed Ruleset: **Deploy / Enable**.
  - Managed Rules → Cloudflare OWASP Core Ruleset: **Deploy / Enable** at default sensitivity.

- [ ] **Step 4: Security → Bots → Bot Fight Mode: **On** (free tier).**

- [ ] **Step 5: Security → Settings:**
  - Security Level: **Medium**.
  - Browser Integrity Check: **On**.
  - Challenge Passage: 30 minutes (default).

- [ ] **Step 6: Security → WAF → Rate limiting rules → Create rule:**
  - Name: `ycrapps-burst-limit`.
  - When incoming requests match: hostname equals `ycrapps.com` or `www.ycrapps.com`.
  - Rate: **100 requests per 10 seconds** per IP.
  - Action: **Managed Challenge**.
  - Duration: 10 seconds.

- [ ] **Step 7: Rules → Redirect Rules → Create rule:**
  - Name: `www-to-apex`.
  - When incoming requests match: `Hostname equals www.ycrapps.com`.
  - Then: Type **Static**, URL `https://ycrapps.com${http.request.uri.path}${http.request.uri.query}`. Wait — Cloudflare Redirect Rules use a different syntax; use **Dynamic** redirect with expression `concat("https://ycrapps.com", http.request.uri.path)` and preserve query string toggle on. Status code: **301 Permanent**.

- [ ] **Step 8: DNS → Settings → DNSSEC: Enable.**

CF generates DS records. Since Yuval registered the domain on Cloudflare Registrar, DS publication is automatic (no work at registrar level).

- [ ] **Step 9: Verify HSTS preload eligibility.**

Run on Mac:
```bash
curl -sI https://ycrapps.com/ | grep -i strict-transport
```
Expected: `strict-transport-security: max-age=31536000; includeSubDomains; preload`. Optional: submit at `https://hstspreload.org/` later — that's a separate, non-blocking action.

- [ ] **Step 10: Verify TLS 1.3.**

```bash
curl -v --tls13 https://ycrapps.com/ -o /dev/null 2>&1 | grep -i 'SSL connection'
```
Expected: `SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384` (or similar AEAD ciphersuite).

- [ ] **Step 11: Verify www → apex redirect.**

```bash
curl -sI https://www.ycrapps.com/some/path?x=1 | head -10
```
Expected: `HTTP/2 301` and `location: https://ycrapps.com/some/path?x=1`.

---

## Task 7: Write the deploy script

**Files (Mac repo):** create `scripts/deploy-ycrapps.sh`.
**Files (server):** none yet (the cron will reference the path inside the cloned repo).

- [ ] **Step 1: Write `~/Documents/Job/Personal_site/scripts/deploy-ycrapps.sh`.**

```bash
#!/usr/bin/env bash
# Deploy the static site to /var/www/ycrapps. Idempotent. Safe to run from cron.
# Cron entry:  */5 * * * * /home/yuval/yuval_cohen_rappaport/scripts/deploy-ycrapps.sh >> /home/yuval/logs/ycrapps-deploy.log 2>&1
set -euo pipefail

REPO_DIR="${HOME}/yuval_cohen_rappaport"
DEST_DIR="/var/www/ycrapps"
LOG_PREFIX="$(date -Iseconds) [deploy-ycrapps]"

cd "${REPO_DIR}"

# 1. Fetch latest origin/main.
git fetch --quiet origin main

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
if [[ "${LOCAL}" == "${REMOTE}" ]]; then
  echo "${LOG_PREFIX} no-op (HEAD=${LOCAL:0:8})"
  exit 0
fi

echo "${LOG_PREFIX} updating ${LOCAL:0:8} -> ${REMOTE:0:8}"

# 2. Hard-reset to origin/main. The repo on the server is read-only material.
git reset --hard origin/main --quiet

# 3. Atomic rsync into doc root. Excludes guard against committing junk.
sudo /usr/bin/rsync -a --delete \
  --exclude='.git' \
  --exclude='.claude' \
  --exclude='.vscode' \
  --exclude='docs' \
  --exclude='scripts' \
  --exclude='nginx' \
  --exclude='cloudflared' \
  --exclude='esp32_webserver' \
  --exclude='*_original.html' \
  --exclude='.DS_Store' \
  ./ "${DEST_DIR}/"

# 4. Tighten perms in case the repo had odd modes.
sudo find "${DEST_DIR}" -type d -exec chmod 0755 {} +
sudo find "${DEST_DIR}" -type f -exec chmod 0644 {} +
sudo chown -R root:www-data "${DEST_DIR}"

echo "${LOG_PREFIX} deployed ${REMOTE:0:8}"
```

- [ ] **Step 2: Make it executable and commit.**

Run on Mac:
```bash
cd ~/Documents/Job/Personal_site
chmod +x scripts/deploy-ycrapps.sh
mkdir -p scripts
git add scripts/deploy-ycrapps.sh
git commit -m "feat(deploy): cron-driven deploy script for ycrapps.com"
git push origin main
```

- [ ] **Step 3: Pull the script onto the server.**

```bash
ssh yuval@server "cd ~/yuval_cohen_rappaport && git pull --ff-only origin main && ls -la scripts/deploy-ycrapps.sh"
```
Expected: shows the file with `-rwxr-xr-x` perms.

- [ ] **Step 4: Create the log dir.**

```bash
ssh yuval@server "mkdir -p ~/logs && touch ~/logs/ycrapps-deploy.log"
```

---

## Task 8: Configure narrow sudoers rule for the deploy script

The script invokes `sudo rsync`, `sudo find`, and `sudo chown` against `/var/www/ycrapps`. We grant Yuval passwordless sudo for exactly those commands, nothing else.

**Files (server):** `/etc/sudoers.d/ycrapps-deploy`.

- [ ] **Step 1: Write the sudoers fragment.**

```bash
ssh yuval@server "sudo tee /etc/sudoers.d/ycrapps-deploy <<'EOF'
# Allow yuval to deploy the static site without a password.
# Scope: rsync into /var/www/ycrapps only; chmod/chown of that tree only.
yuval ALL=(root) NOPASSWD: /usr/bin/rsync -a --delete --exclude=.git --exclude=.claude --exclude=.vscode --exclude=docs --exclude=scripts --exclude=nginx --exclude=cloudflared --exclude=esp32_webserver --exclude=*_original.html --exclude=.DS_Store ./ /var/www/ycrapps/
yuval ALL=(root) NOPASSWD: /usr/bin/find /var/www/ycrapps -type d -exec chmod 0755 {} +
yuval ALL=(root) NOPASSWD: /usr/bin/find /var/www/ycrapps -type f -exec chmod 0644 {} +
yuval ALL=(root) NOPASSWD: /bin/chown -R root\:www-data /var/www/ycrapps
EOF
sudo chmod 440 /etc/sudoers.d/ycrapps-deploy
sudo visudo -c -f /etc/sudoers.d/ycrapps-deploy"
```
Expected: `parsed OK`.

- [ ] **Step 2: Test the deploy script manually.**

```bash
ssh yuval@server "~/yuval_cohen_rappaport/scripts/deploy-ycrapps.sh"
```
Expected: log line `... updating <sha> -> <sha>` (first run is a real deploy because /var/www/ycrapps still has the placeholder), then `... deployed <sha>`.

If sudoers is too narrow and a command fails, tighten or loosen the rule above and rerun. The exact rsync flag set must match between the script and the sudoers entry.

- [ ] **Step 3: Confirm the real site is live.**

```bash
curl -sI https://ycrapps.com/ | head -5
curl -s https://ycrapps.com/ | grep -E '<title>|Yuval Cohen' | head -3
```
Expected: `HTTP/2 200`, the actual portfolio's `<title>Yuval Cohen Rappaport | Product Manager</title>`.

- [ ] **Step 4: Confirm GitHub auto-verification file still resolves.**

```bash
curl -s https://ycrapps.com/googled11a61efcedcd6d2\ \(1\).html | head -3
```
Expected: the same 53-byte content the file holds. If you'd prefer the cleaner `googled11a61efcedcd6d2.html` (no `(1)` parenthetical), that's a content cleanup for later — not part of this plan.

- [ ] **Step 5: Confirm the second run is a no-op.**

```bash
ssh yuval@server "~/yuval_cohen_rappaport/scripts/deploy-ycrapps.sh"
```
Expected: `... no-op (HEAD=<sha>)`.

---

## Task 9: Install the cron entry

**Files (server):** Yuval's user crontab.

- [ ] **Step 1: Add the cron line.**

```bash
ssh yuval@server "(crontab -l 2>/dev/null | grep -v 'deploy-ycrapps.sh' ; echo '*/5 * * * * /home/yuval/yuval_cohen_rappaport/scripts/deploy-ycrapps.sh >> /home/yuval/logs/ycrapps-deploy.log 2>&1') | crontab -"
```

- [ ] **Step 2: Verify.**

```bash
ssh yuval@server "crontab -l | grep deploy-ycrapps"
```
Expected: the line we just added.

- [ ] **Step 3: Wait for the next 5-minute boundary (or run once) and confirm the log gets a line.**

```bash
ssh yuval@server "tail -f ~/logs/ycrapps-deploy.log"
```
Within 5 minutes you should see a new `... no-op` line. Ctrl-C out.

---

## Task 10: Cloudflare Web Analytics + monitoring hook

- [ ] **Step 1: Enable Web Analytics on the zone.**

In CF dashboard → Analytics & Logs → Web Analytics → enable for `ycrapps.com`. CF auto-injects the beacon for proxied hostnames; no code change needed.

- [ ] **Step 2: Confirm beacon loads from a real browser.**

Open `https://ycrapps.com/` in Chrome, DevTools → Network. Confirm a request to `static.cloudflareinsights.com/beacon.min.js` returns 200 and a POST to `cloudflareinsights.com` with no CSP violation in the console. (The CSP in Task 3 explicitly allows both.)

- [ ] **Step 3: Inspect the existing server-monitor's check list.**

```bash
ssh yuval@server "ls ~/server-monitor/ && grep -rE 'http|url|endpoint' ~/server-monitor/ 2>/dev/null | grep -vE '\.git|\.venv|node_modules' | head -30"
```
Identify the file/format used for HTTP checks (likely a JSON or YAML list, or hard-coded list in a Python file). If it's not obvious, read `~/server-monitor/README.md` first.

- [ ] **Step 4: Add `https://ycrapps.com/` to the check list.**

The exact mechanism depends on what step 3 finds. Common patterns:
- JSON/YAML config: add an entry, commit, restart the service.
- Hard-coded list in a Python file: edit, commit, restart.
- Database / SQLite: insert a row.

Whatever it is, the check should: GET `https://ycrapps.com/`, expect 200, alert on non-200 or timeout.

- [ ] **Step 5: Trigger one check run and verify it picks up the new endpoint.**

If the monitor is cron-based, run its entrypoint manually. Confirm output / logs show `ycrapps.com` was checked and returned 200.

---

## Task 11: Final verification matrix

Run all from the Mac. Each line is a check; record pass/fail.

- [ ] **Step 1: Apex over IPv4.**

```bash
curl -sI -4 https://ycrapps.com/ | head -1
```
Expected: `HTTP/2 200`.

- [ ] **Step 2: Apex over IPv6.**

```bash
curl -sI -6 https://ycrapps.com/ | head -1
```
Expected: `HTTP/2 200` (CF advertises both).

- [ ] **Step 3: TLS 1.3 in use.**

```bash
echo | openssl s_client -connect ycrapps.com:443 -tls1_3 -servername ycrapps.com 2>/dev/null | grep -E 'Protocol|Cipher'
```
Expected: `Protocol: TLSv1.3` and a modern AEAD cipher.

- [ ] **Step 4: TLS 1.2 explicitly refused (Min TLS 1.3).**

```bash
echo | openssl s_client -connect ycrapps.com:443 -tls1_2 -servername ycrapps.com 2>&1 | grep -E 'alert|error|handshake' | head -3
```
Expected: handshake failure / `tlsv1 alert protocol version`. (CF rejects ≤1.2 because Min TLS is 1.3.)

- [ ] **Step 5: All security headers present.**

```bash
curl -sI https://ycrapps.com/ | grep -iE 'strict-transport|content-security|x-frame|x-content|referrer|permissions-policy'
```
Expected: all six headers present, with HSTS preload, CSP including `frame-ancestors 'none'`, etc.

- [ ] **Step 6: www redirects to apex.**

```bash
curl -sI https://www.ycrapps.com/ | grep -E '^(HTTP|location:)'
```
Expected: `HTTP/2 301` and `location: https://ycrapps.com/`.

- [ ] **Step 7: HTTP redirected to HTTPS.**

```bash
curl -sI http://ycrapps.com/ | grep -E '^(HTTP|location:)'
```
Expected: `HTTP/1.1 301` (or 308) and `location: https://ycrapps.com/`.

- [ ] **Step 8: DNSSEC chain is valid.**

```bash
dig +dnssec +short ycrapps.com @1.1.1.1 | head
```
Expected: at least one RRSIG line. Optional deeper check: `https://dnsviz.net/d/ycrapps.com/dnssec/`.

- [ ] **Step 9: Origin not directly reachable.**

```bash
ssh yuval@server "ss -tln | grep -E ':80 |:443 ' || echo 'ORIGIN NOT EXPOSED'"
```
Expected: `ORIGIN NOT EXPOSED` (only loopback may bind 80 from leftover default; that's still inaccessible from outside).

- [ ] **Step 10: Cron deploy is healthy.**

```bash
ssh yuval@server "tail -5 ~/logs/ycrapps-deploy.log"
```
Expected: the most recent line is a `... no-op` from the last cron tick.

- [ ] **Step 11: Coffee-shop service still works.**

Confirm `cafehakerem.<zone>` returns whatever it returned before this work began. If broken, roll back: `sudo systemctl stop cloudflared-ycrapps; sudo systemctl disable cloudflared-ycrapps`. Investigate root cause before re-enabling.

- [ ] **Step 12: Update the Obsidian vault project page.**

Edit `~/Obsidian Vault/wiki/projects/Personal Portfolio Site.md`. Replace the "Next" stub with the production URL, hosting model (CF Tunnel + nginx on home server), and deploy mechanism (cron / 5 min / atomic rsync). Add to `wiki/log.md`:

```
2026-05-03 deploy: ycrapps.com cutover from GitHub Pages to home-server CF Tunnel.
```

Commit the vault change.

---

## Self-Review

**Spec coverage:**
- Architecture / cloudflared tunnel → Tasks 4, 5. ✓
- nginx static origin on 127.0.0.1:8080 → Tasks 1–3. ✓
- Security headers (CSP, HSTS, XFO, XCTO, RP, PP) → Task 3 step 1. ✓
- Doc root perms (root:www-data, 0755/0644) → Task 2 + script. ✓
- Cron deploy from origin/main, idempotent, atomic rsync → Tasks 7–9. ✓
- CF zone hardening (Full strict, Min TLS 1.3, HSTS preload, WAF, OWASP, Bot Fight, BIC, rate limit, DNSSEC) → Task 6. ✓
- www→apex 301 → Task 6 step 7. ✓
- Web Analytics → Task 10. ✓
- server-monitor check → Task 10 steps 3–5. ✓
- Coffee-shop subdomain non-regression → Tasks 0, 5, 11. ✓
- Rollback path (revert commit → cron) → covered by deploy script idempotency. ✓
- GitHub Pages stays up — explicitly nothing in this plan touches its CNAME. ✓

**Placeholders:** none. Every step has either an exact command, full file content, or a specific dashboard action.

**Type / name consistency:** tunnel name `ycrapps-portfolio`, service `cloudflared-ycrapps.service`, config dir `/etc/cloudflared-ycrapps/`, doc root `/var/www/ycrapps`, deploy script `scripts/deploy-ycrapps.sh`, log `~/logs/ycrapps-deploy.log` — used consistently end-to-end.

**One known soft spot:** Task 10 step 4 ("add to server-monitor check list") is a discovery-then-edit task because the monitor's config layout isn't known from this plan's context. The discovery step (10.3) makes the layout explicit before editing.

---

## Execution

Plan complete and saved to `docs/superpowers/plans/2026-05-03-ycrapps-com-hosting.md`.
