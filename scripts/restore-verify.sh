#!/usr/bin/env bash
# Restores the latest backup into a THROWAWAY MySQL container and validates it.
#
# This is the differentiator. Almost everyone stops at "the backup script exits
# 0." A backup you have never restored is not a backup — it is a hypothesis.
#
# Run this from WSL, not from the database node: it needs Docker, and the db
# nodes have no reason to have a container runtime installed.
#
#   export BACKUP_BUCKET=$(cd terraform && terraform output -raw backup_bucket)
#   ./scripts/restore-verify.sh
set -euo pipefail

BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET must be set}"
WORK="$(mktemp -d)"
CONTAINER="restore-verify-$$"
trap 'rm -rf "$WORK"; docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

LATEST="$(aws s3 ls "s3://${BUCKET}/logical/" \
          | grep -E '\.sql\.gz$' | sort | tail -1 | awk '{print $4}')"

if [[ -z "$LATEST" ]]; then
  log "FATAL: no backups found in s3://${BUCKET}/logical/"
  exit 1
fi
log "Latest backup: $LATEST"

aws s3 cp "s3://${BUCKET}/logical/${LATEST}"        "$WORK/"
aws s3 cp "s3://${BUCKET}/logical/${LATEST}.sha256" "$WORK/"

log "Verifying checksum"
( cd "$WORK" && sha256sum -c "${LATEST}.sha256" )

log "Starting scratch MySQL instance"
docker run -d --name "$CONTAINER" \
  -e MYSQL_ROOT_PASSWORD=verify \
  mysql:8.0 >/dev/null

# `mysqladmin ping` is NOT a readiness check. It exits 0 even on ERROR 1045,
# because the server did answer — "access denied" still proves something is
# listening. Worse, the official image runs a TEMPORARY server during
# initialisation (socket only, "port: 0"), then shuts it down and starts the
# real one. A naive probe therefore succeeds against a server that is about to
# disappear, and the next command fails with either ERROR 2002 (socket gone) or
# ERROR 1045 (root password not configured yet), at random.
#
# Only the final server logs "ready for connections" with "port: 3306". Wait for
# that, then confirm with a query that actually authenticates.
log "Waiting for the scratch instance to accept authenticated connections"
for i in $(seq 1 60); do
  if docker logs "$CONTAINER" 2>&1 | grep -q 'ready for connections.*port: 3306' \
     && docker exec "$CONTAINER" mysql -uroot -pverify -e 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  if [[ $i -eq 60 ]]; then
    log "FATAL: scratch instance never became ready"
    docker logs "$CONTAINER" 2>&1 | tail -20
    exit 1
  fi
  sleep 2
done

# The dump carries SET @@GLOBAL.GTID_PURGED, which a server with existing GTIDs
# refuses. Clear them first so the restore is a faithful replay.
log "Clearing GTID state on the scratch instance"
docker exec "$CONTAINER" mysql -uroot -pverify \
  -e "RESET BINARY LOGS AND GTIDS" 2>/dev/null \
  || docker exec "$CONTAINER" mysql -uroot -pverify -e "RESET MASTER"

log "Restoring"
START=$(date +%s)
gunzip -c "$WORK/$LATEST" | docker exec -i "$CONTAINER" mysql -uroot -pverify
END=$(date +%s)
log "Restore completed in $((END-START))s"

log "Validating restored data"
docker exec "$CONTAINER" mysql -uroot -pverify -N -e "
  SELECT CONCAT('schemas: ', COUNT(*)) FROM information_schema.schemata
   WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');
  SELECT CONCAT('tables: ',  COUNT(*)) FROM information_schema.tables
   WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys');
  SELECT CONCAT('visits rows: ', COUNT(*)) FROM appdb.visits;
"

# Integrity check across every restored table.
#
# This used to shell out to `mysqlcheck`, which is NOT present in recent
# mysql:8.0 images. The exec failed, the pipe carried nothing, grep exited
# non-zero, and `|| log "All tables OK"` fired on that failure — so the script
# reported a clean integrity check it had never performed. In a tool whose whole
# job is proving a backup is real, a silent false pass is the worst outcome
# available.
#
# CHECK TABLE is the same server-side operation, reachable through the `mysql`
# client that is always present. The table count is printed so that "checked
# nothing" can never again look like "everything is fine".
# MYSQL_PWD rather than -pverify: the client prints "Using a password on the
# command line interface can be insecure" to STDERR, and this block captures
# stderr so that a genuine error cannot vanish. That warning does not end in
# "OK", so with -p it is reported as an integrity problem — a false positive
# exactly as misleading as the false negative it replaced.
log "Running integrity check across all restored tables"
CHECK_OUT="$(docker exec -e MYSQL_PWD=verify "$CONTAINER" mysql -uroot -N -B -e "
  SELECT CONCAT('CHECK TABLE \`', table_schema, '\`.\`', table_name, '\`;')
    FROM information_schema.tables
   WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
     AND table_type = 'BASE TABLE';" \
  | docker exec -i -e MYSQL_PWD=verify "$CONTAINER" mysql -uroot -N -B 2>&1)"

if [[ -z "$CHECK_OUT" ]]; then
  log "FATAL: integrity check produced no output — it did not run"
  exit 1
fi

BAD="$(printf '%s\n' "$CHECK_OUT" | grep -v 'OK$' || true)"
if [[ -n "$BAD" ]]; then
  log "INTEGRITY PROBLEMS FOUND:"
  printf '%s\n' "$BAD"
  exit 1
fi
log "All tables OK ($(printf '%s\n' "$CHECK_OUT" | wc -l) checked)"

log "RESTORE VERIFIED — recovery time $((END-START))s"
log "Record this run in docs/DR-test-results.md"
