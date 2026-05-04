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
