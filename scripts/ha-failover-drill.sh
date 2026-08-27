#!/usr/bin/env bash
# Proves the platform survives losing a web node, and MEASURES the gap.
#
#   ./scripts/ha-failover-drill.sh https://lab.syedamjad.com/healthz i-0abc123
#
# Get a web instance id with:
#   cd terraform && terraform output -json web_instance_ids | jq -r '.[0]'
set -euo pipefail

URL="${1:?usage: ha-failover-drill.sh <url> <instance-id-to-stop>}"
INSTANCE="${2:?usage: ha-failover-drill.sh <url> <instance-id-to-stop>}"
LOG="${DRILL_LOG:-/tmp/drill.log}"

echo "==> Baseline — 10 requests"
for _ in $(seq 1 10); do
  curl -s -o /dev/null -w '%{http_code} ' "$URL"
done
echo

echo "==> Starting continuous probe (1/s)"
: > "$LOG"
(
  while true; do
    printf '%s %s\n' \
      "$(date -u +%T)" \
      "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL")"
    sleep 1
  done
) >> "$LOG" &
PROBE=$!
trap 'kill $PROBE 2>/dev/null || true' EXIT

sleep 5
echo "==> Stopping $INSTANCE"
aws ec2 stop-instances --instance-ids "$INSTANCE" >/dev/null
STOP_AT="$(date -u +%T)"

echo "==> Observing for 120s"
sleep 120
kill $PROBE 2>/dev/null || true
sleep 1

TOTAL=$(wc -l < "$LOG")
FAILED=$(grep -vc ' 200$' "$LOG" || true)

cat <<EOF

=== Failover drill result ===
Instance stopped at : $STOP_AT UTC
Total probes        : $TOTAL
Failed (non-200)    : $FAILED
Availability        : $(awk "BEGIN{printf \"%.2f%%\", (($TOTAL-$FAILED)/$TOTAL)*100}")

Non-200 responses:
EOF
grep -v ' 200$' "$LOG" || echo "  none — zero-impact failover"

cat <<EOF

Full probe log: $LOG
Record the numbers in docs/DR-test-results.md, then restart the node:
  aws ec2 start-instances --instance-ids $INSTANCE
EOF
