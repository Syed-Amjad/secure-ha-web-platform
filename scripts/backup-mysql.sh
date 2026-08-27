#!/usr/bin/env bash
# Nightly logical backup to S3, encrypted with KMS.
#
# Three things here that most backup scripts lack: a minimum-size sanity check,
# a gzip integrity test, and a recorded SHA256 so the restore can prove it got
# the same bytes back.
set -euo pipefail

BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET must be set}"
KMS_KEY="${KMS_KEY_ID:?KMS_KEY_ID must be set}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DUMP="$WORK/mysql-${STAMP}.sql.gz"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

log "Starting logical backup"
# --single-transaction   consistent snapshot without locking the whole server
# --source-data=2        record the binlog coordinates as a comment
# --set-gtid-purged=ON   so a restored copy can be attached as a replica
mysqldump \
  --all-databases \
  --single-transaction \
  --source-data=2 \
  --set-gtid-purged=ON \
  --routines --triggers --events \
  --hex-blob \
  | gzip -6 > "$DUMP"

# Fail loudly on an empty or truncated dump rather than uploading garbage over
# the top of yesterday's good backup.
SIZE=$(stat -c%s "$DUMP")
if [[ "$SIZE" -lt 1024 ]]; then
  log "FATAL: dump is only ${SIZE} bytes — aborting"
  exit 1
fi
log "Dump size: ${SIZE} bytes"

log "Verifying gzip integrity"
gzip -t "$DUMP"

SHA="$(sha256sum "$DUMP" | awk '{print $1}')"
# Written as "<hash>  <filename>" so `sha256sum -c` can consume it directly
# during restore-verify.sh.
printf '%s  %s\n' "$SHA" "$(basename "$DUMP")" > "${DUMP}.sha256"
log "SHA256: $SHA"

log "Uploading to s3://${BUCKET}/logical/"
aws s3 cp "$DUMP"          "s3://${BUCKET}/logical/" --sse aws:kms --sse-kms-key-id "$KMS_KEY"
aws s3 cp "${DUMP}.sha256" "s3://${BUCKET}/logical/" --sse aws:kms --sse-kms-key-id "$KMS_KEY"

log "Backup complete: $(basename "$DUMP")"
