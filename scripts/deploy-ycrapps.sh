#!/usr/bin/env bash
# Deploy the static site to /var/www/ycrapps. Idempotent. Safe to run from cron.
# Cron entry:  */5 * * * * /home/yuval/yuval_cohen_rappaport/scripts/deploy-ycrapps.sh >> /home/yuval/logs/ycrapps-deploy.log 2>&1
set -euo pipefail

REPO_DIR="${HOME}/yuval_cohen_rappaport"
DEST_DIR="/var/www/ycrapps"
STATE_FILE="${HOME}/.local/state/ycrapps-deployed-sha"
LOG_PREFIX="$(date -Iseconds) [deploy-ycrapps]"

mkdir -p "$(dirname "${STATE_FILE}")"
cd "${REPO_DIR}"

# 1. Fetch latest origin/main and align HEAD.
git fetch --quiet origin main
git reset --hard origin/main --quiet
HEAD_SHA="$(git rev-parse HEAD)"

# 2. Skip if the deployed tree already matches HEAD.
DEPLOYED="$(cat "${STATE_FILE}" 2>/dev/null || true)"
if [[ "${DEPLOYED}" == "${HEAD_SHA}" ]]; then
  echo "${LOG_PREFIX} no-op (deployed=${HEAD_SHA:0:8})"
  exit 0
fi

PREV_DISPLAY="${DEPLOYED:0:8}"
echo "${LOG_PREFIX} deploying ${HEAD_SHA:0:8} (was ${PREV_DISPLAY:-none})"

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

echo "${HEAD_SHA}" > "${STATE_FILE}"
echo "${LOG_PREFIX} deployed ${HEAD_SHA:0:8}"
