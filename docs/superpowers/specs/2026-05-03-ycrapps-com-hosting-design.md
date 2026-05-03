# ycrapps.com — Self-hosted Portfolio via Cloudflare Tunnel

**Date:** 2026-05-03
**Status:** Approved design — ready for implementation plan
**Owner:** Yuval

## Goal

Move the personal portfolio site (currently a static `index.html` in
`github.com/yuvalcohenrappaport/yuval_cohen_rappaport`, presumed served by
GitHub Pages) to the apex domain `ycrapps.com`, hosted on Yuval's home
server, fronted by Cloudflare. Hardened by default. No inbound port
opened on the home network.

## Constraints

- Home network has AP isolation; landlord-managed router cannot be
  reconfigured to forward ports 80/443. Inbound exposure is not an
  option.
- Server is reachable today only over Tailscale.
- `ycrapps.com` is registered on Cloudflare Registrar; nameservers
  already point to Cloudflare. Cloudflare account exists with a working
  zone.
- A separate subdomain (`cafehakerem.*`, exact zone TBC by Yuval) is
  already in production. This work must not touch its DNS, its tunnel,
  or its origin service.
- The site is purely static (single `index.html`, ~71KB, one inline
  `<script>` for the particle background, Google Fonts, mailto, no
  forms, no analytics).
- Existing infra patterns on the box: cron-based services (no Docker),
  systemd user units, hourly server-monitor, nightly bodyguard, weekly
  audit. The website sync audit module already operates against
  `~/yuval_cohen_rappaport/`.

## Non-goals

- Replacing or hardening unrelated services (Postgres on `0.0.0.0:5432`,
  MQTT on `0.0.0.0:1883`) — flagged separately.
- Taking down the existing GitHub Pages deployment. It stays up.
- Adding a backend, contact form, or any dynamic content.
- Changing the design / content of the site itself.

## Architecture

```
GitHub repo                Cloudflare edge                  Server (Tailscale only)
yuval_cohen_rappaport       ┌─────────────────┐           ┌─────────────────────────┐
        │                   │ ycrapps.com     │           │ cloudflared (systemd)    │
        │                   │  TLS terminate  │◄═════════►│   ↓ outbound 443 only    │
        │                   │  WAF / Bot      │  Tunnel   │ nginx 127.0.0.1:8080     │
        │                   │  Web Analytics  │           │   ↓                      │
        │                   └─────────────────┘           │ /var/www/ycrapps/        │
        │                                                 │   ↑ rsync atomic         │
        └─────────────────────────────────────────────────│ ~/yuval_cohen_rappaport/ │
                                                          │   ↑ git pull (cron 5m)   │
                                                          └─────────────────────────┘
```

**Trust direction:** every connection is initiated outbound from the
origin (cloudflared → CF, server → GitHub). The home router never
accepts an inbound connection. Origin IP is not advertised in DNS.

## Components

### Server: nginx (static origin, localhost only)

- Listens on `127.0.0.1:8080`. Never `0.0.0.0`, never `:443`.
- Serves `/var/www/ycrapps/` as the document root. `index.html` only.
  No autoindex, no PHP, no proxying, no aliases outside the doc root.
- `server_tokens off`. Gzip + brotli enabled for text MIME types.
- Cache policy: HTML is `Cache-Control: no-cache`. Hashed assets (none
  today, future-proofed) get `max-age=31536000, immutable`.
- Security headers applied to every response:
  - `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`
  - `Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self' 'unsafe-inline' https://static.cloudflareinsights.com; connect-src 'self' https://cloudflareinsights.com; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'none'`
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Referrer-Policy: strict-origin-when-cross-origin`
  - `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()`
- Filesystem: `/var/www/ycrapps` is `root:www-data`, dirs `0755`,
  files `0644`. nginx worker user (`www-data`) cannot write content.

### Server: cloudflared (tunnel client)

- Installed via the official .deb (or apt repo).
- A **new, dedicated tunnel** (e.g. `ycrapps-portfolio`) created from
  the Cloudflare Zero Trust dashboard. Token-authenticated. Existing
  tunnels (in particular the one serving `cafehakerem.*`) are not
  reused, not modified, and not stopped during install. Isolation
  prevents a misconfig from affecting the coffee-shop service.
- Configuration:
  - Single ingress rule: `ycrapps.com → http://127.0.0.1:8080`.
  - Catch-all rule: `http_status:404`. The tunnel cannot be repurposed
    to reach `localhost:5432`, `localhost:1883`, or any other origin
    service.
- Runs as a systemd service installed via `cloudflared service install <token>`.
  Runs under its own system user; not Yuval's home dir.
- Credentials at `/etc/cloudflared/credentials.json`, mode `0600`,
  owned `root:root`.

### Server: deploy script + cron

- Path: `~/bin/deploy-ycrapps.sh`. Logged to `~/logs/ycrapps-deploy.log`.
- Logic (idempotent):
  1. `cd ~/yuval_cohen_rappaport && git fetch origin main`.
  2. If `git rev-parse HEAD` equals `git rev-parse origin/main` → exit 0.
  3. `git reset --hard origin/main`.
  4. `rsync -a --delete --exclude='.git' --exclude='.claude' --exclude='.vscode' --exclude='*_original.html' ./ /var/www/ycrapps/`
     via a narrow sudoers rule (or `setcap`-equivalent) limited to that
     destination — no other write target permitted.
  5. If nginx config files changed: `sudo nginx -t && sudo systemctl reload nginx`.
- Cron entry (yuval's crontab):
  `*/5 * * * * /home/yuval/bin/deploy-ycrapps.sh >> /home/yuval/logs/ycrapps-deploy.log 2>&1`.
- Existing weekly audit (`~/audits/modules/website-sync`) is unchanged
  and continues to PR project-card updates against the repo; the cron
  applies them automatically after merge.

### Cloudflare zone

- **DNS:** the new tunnel creates `CNAME ycrapps.com → <new-uuid>.cfargotunnel.com`
  (proxied) and the same for `www`. No `A`/`AAAA`. **DNSSEC enabled.**
  The existing `cafehakerem.*` record is independent and untouched.
- **TLS:**
  - SSL/TLS mode: **Full (strict)**.
  - Always Use HTTPS: on.
  - Min TLS Version: **1.3**.
  - Automatic HTTPS Rewrites: on.
  - HSTS: on, max-age 12 months, includeSubDomains, preload.
- **WAF / Bot:**
  - Cloudflare Managed Ruleset: on.
  - OWASP Core Ruleset: on, default sensitivity.
  - Bot Fight Mode: on.
  - Browser Integrity Check: on.
  - Security Level: Medium.
- **Rate limiting:** one rule on free plan — `>100 requests / 10s per
  IP` to any path → managed challenge.
- **Redirects (Bulk Redirects or single redirect rule):**
  `https://www.ycrapps.com/*` → 301 → `https://ycrapps.com/$1`,
  preserving path and query.
- **Web Analytics:** auto-injected snippet enabled for the zone (or
  added manually in `index.html` before `</body>`). CSP above already
  allows `static.cloudflareinsights.com` and `cloudflareinsights.com`.

## Hardening summary

| Layer | Control | Threat addressed |
|---|---|---|
| Origin network | nginx bound to `127.0.0.1:8080`; UFW verified to keep 80/443 closed | Direct origin scan / unintended exposure |
| Tunnel | One hostname, catch-all 404 | Lateral use of tunnel to reach other localhost services |
| Tunnel | cloudflared runs as its own system user | Privilege escalation from tunnel compromise |
| TLS | Full (strict) + TLS 1.3 + HSTS preload | Downgrade / MITM at edge |
| HTTP | Locked CSP, `frame-ancestors 'none'`, `form-action 'none'` | XSS, clickjacking, form injection |
| HTTP | `server_tokens off` | Version fingerprinting |
| WAF | Managed + OWASP rulesets, Bot Fight, rate-limit | Generic web attacks, scraping, brute-force |
| DNS | DNSSEC on | DNS hijack of apex |
| Filesystem | `/var/www/ycrapps` root-owned, 0644/0755 | Worker process content tampering |
| Deploy | Cron pulls main only, `git reset --hard`, atomic rsync `--delete` | Drift; supply-chain via push |
| Deploy | No CI secrets, no inbound webhook | New attack surface from deploy mechanism |
| Observability | Add `https://ycrapps.com/` to server-monitor HTTP checks | Silent outage |

## Operational

- **Rollback:** `git revert <sha>` and push → cron applies within 5 min.
  On-server emergency: `git reset --hard <good-sha> && ~/bin/deploy-ycrapps.sh`.
- **Monitoring:** add `https://ycrapps.com/` to the existing
  server-monitor HTTP check list. nginx access/error logs at the
  default paths; Bodyguard already tails system logs.
- **Verification of cutover:** GitHub Pages remains up. Verify
  ycrapps.com over public network (e.g. phone on cellular) before
  changing any links from the GitHub Pages address. Cutover is purely
  by where Yuval shares the URL — DNS already points only to the new
  zone.

## Out of scope (explicit)

- Postgres `0.0.0.0:5432` and MQTT `0.0.0.0:1883` exposure on the
  server. Pre-existing; separate hardening item.
- Removing the GitHub Pages deployment. Stays up; revisit later.
- Removing `index_original.html` or the Google verification HTML from
  the repo. The rsync exclude takes care of `index_original.html`; the
  verification file is intentionally served.
- Backend / contact form / dynamic features.

## Open risks

- **Inline `<script>` requires `'unsafe-inline'` in CSP.** A future
  hardening pass should extract the particle script to a hashed file
  and drop `'unsafe-inline'` from `script-src`. Not part of this work.
- **Cloudflare Web Analytics snippet is auto-injected by CF when the
  zone setting is on.** If injection is disabled or fails, manually add
  the snippet to `index.html`.
- **One rate-limit rule on the free plan.** If abuse patterns appear
  later, upgrading or shifting to Cloudflare Workers may be needed.
- **Confirm exact subdomain zone with Yuval before implementation.**
  The clarification "cafehakerem.ycrapp.com" was likely a typo for
  "cafehakerem.ycrapps.com" — design assumes same zone. If the
  coffee-shop subdomain is on a different zone (`ycrapp.com`), the
  design still holds since zones are fully isolated, but the precondition
  check at implementation time should verify the actual record.
