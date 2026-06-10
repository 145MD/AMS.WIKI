#!/usr/bin/env bash
#
# pg-backup.sh — nightly logical backup of the AMS Postgres DB.
#   * pg_dump custom format (-Fc), gzipped
#   * local GFS-style retention (keep 7 days on disk)
#   * upload to Azure Blob (offsite); offsite retention is enforced by an
#     Azure Blob lifecycle rule on the container, NOT here
#   * optional dead-man's-switch ping on success
#
# Reads secrets from /etc/ams/backup.env (chmod 600):
#   PGPASSWORD                         password for the ams_backup role
#   AZURE_STORAGE_CONNECTION_STRING    storage account connection string
#   BACKUP_CONTAINER                   target container (e.g. db-backups)
#   HEALTHCHECK_URL                    optional; curl'd on success
#
# Install:
#   install -m 750 pg-backup.sh /usr/local/bin/pg-backup.sh
#   (run via ams-pg-backup.timer)
#
set -euo pipefail

ENV_FILE=/etc/ams/backup.env
BACKUP_DIR=/var/backups/ams/postgres
LOG_FILE=/var/log/ams/backup.log
DB_NAME=ams_prod
DB_USER=ams_backup
DB_HOST=localhost
RETAIN_DAYS=7

exec >>"$LOG_FILE" 2>&1
echo "=== pg-backup $(date --iso-8601=seconds) ==="

# shellcheck disable=SC1090
source "$ENV_FILE"
export PGPASSWORD

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="$BACKUP_DIR/${DB_NAME}_${STAMP}.dump.gz"

# 1. Dump (custom format streamed through gzip)
pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -Fc \
  | gzip -9 > "$OUT"
echo "dump ok: $OUT ($(du -h "$OUT" | cut -f1))"

# 2. Upload offsite to Azure Blob
az storage blob upload \
  --connection-string "$AZURE_STORAGE_CONNECTION_STRING" \
  --container-name "$BACKUP_CONTAINER" \
  --name "postgres/$(basename "$OUT")" \
  --file "$OUT" \
  --overwrite false
echo "uploaded: postgres/$(basename "$OUT")"

# 3. Local retention (offsite retention is an Azure lifecycle rule)
find "$BACKUP_DIR" -name "${DB_NAME}_*.dump.gz" -mtime +"$RETAIN_DAYS" -print -delete

# 4. Dead-man's switch
if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
  curl -fsS -m 10 "$HEALTHCHECK_URL" >/dev/null && echo "healthcheck pinged"
fi

echo "=== done ==="
