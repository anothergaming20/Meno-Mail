#!/usr/bin/env bash
# dispatcher.sh — entry point for email triage
# Triggered by OpenClaw cron (every 15 min). Fetches new emails and runs
# the full triage pipeline via Lobster (email-triage.lobster).

set -euo pipefail

# Ensure node@22 is on PATH for openclaw and lobster calls.
export PATH="/usr/local/opt/node@22/bin:$PATH"

LOCKFILE="/tmp/email-triage-dispatcher.lock"
WORKFLOW="${TRIAGE_WORKFLOW:-$HOME/.openclaw/workspace/workflows/email-triage.lobster}"

# ── Overlap guard: skip if previous run is still going ──
if [ -f "$LOCKFILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -lt 600 ]; then
    echo "Previous run still active (${LOCK_AGE}s old). Skipping."
    exit 0
  else
    echo "Stale lock (${LOCK_AGE}s). Removing and proceeding."
    rm -f "$LOCKFILE"
  fi
fi
trap 'rm -f "$LOCKFILE"' EXIT
touch "$LOCKFILE"

# ── Fetch unprocessed email IDs ──
EMAIL_IDS=$(gws gmail users messages list \
  --params '{"userId":"me","q":"-label:Triage/Processed is:inbox newer_than:30d","maxResults":50}' \
  2>/dev/null | jq -r '.messages[]?.id // empty')

if [ -z "$EMAIL_IDS" ]; then
  echo "No new emails to process."
  exit 0
fi

# ── Process each email via Lobster workflow ──
COUNT=0
ERRORS=0

for EMAIL_ID in $EMAIL_IDS; do
  echo "Processing: $EMAIL_ID"
  if lobster run --file "$WORKFLOW" \
       --args-json "{\"email_id\":\"$EMAIL_ID\"}" 2>/dev/null; then
    echo "  [$EMAIL_ID] done"
    COUNT=$((COUNT + 1))
  else
    echo "  [$EMAIL_ID] ERROR" >&2
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "Done: $COUNT processed, $ERRORS errors."

# ── Notify Telegram only if something happened ──
if [ $COUNT -gt 0 ] || [ $ERRORS -gt 0 ]; then
  MSG="📧 Email Triage Done"$'\n'"✅ $COUNT processed"
  [ $ERRORS -gt 0 ] && MSG="$MSG"$'\n'"⚠️ $ERRORS errors"
  openclaw message send \
    --channel telegram \
    --target "1771281565" \
    --message "$MSG" 2>/dev/null || true
fi
