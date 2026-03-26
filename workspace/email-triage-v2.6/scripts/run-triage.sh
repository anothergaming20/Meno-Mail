#!/usr/bin/env bash
# run-triage.sh — Email triage pipeline runner. (v2.6)
#
# Called by the OpenClaw email-triage agent via the exec tool during its
# isolated cron session. The agent's session transcript captures this
# execution automatically — no separate logging infrastructure needed.
#
# Replaces dispatcher.sh. Key differences from v2.5:
# - No longer needs to be a standalone cron job with its own PATH setup.
#   The agent session inherits PATH and MATON_API_KEY from OpenClaw.
# - No Telegram summary at the end — the agent session itself is the record.
#   Telegram notifications for errors can be added to the agent's AGENTS.md
#   instructions if desired.
# - Outputs structured JSON lines so the agent can read and summarize results.

set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

LOCKFILE="/tmp/email-triage-dispatcher.lock"
WORKFLOW="${TRIAGE_WORKFLOW:-$HOME/.openclaw/workspace/workflows/email-triage.lobster}"
MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"
LOG_FILE="${TRIAGE_LOG:-$HOME/.openclaw/workspace/data/logs/triage.jsonl}"

mkdir -p "$(dirname "$LOG_FILE")"

# ── Structured log helper ────────────────────────────────────────────
log() {
  local level="$1" msg="$2" extra="${3:-{}}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"ts\":\"$ts\",\"level\":\"$level\",\"msg\":\"$msg\",\"data\":$extra}" | tee -a "$LOG_FILE"
}

# ── Overlap guard ────────────────────────────────────────────────────
if [ -f "$LOCKFILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -lt 600 ]; then
    log "warn" "Previous run still active, skipping" "{\"lock_age_seconds\":$LOCK_AGE}"
    exit 0
  else
    log "warn" "Stale lock detected, removing" "{\"lock_age_seconds\":$LOCK_AGE}"
    rm -f "$LOCKFILE"
  fi
fi
trap 'rm -f "$LOCKFILE"' EXIT
touch "$LOCKFILE"

log "info" "Triage run started" "{}"

# ── Fetch unprocessed email IDs via Maton ────────────────────────────
EMAIL_IDS_JSON=$(curl -sf -G \
  -H "Authorization: Bearer ${MATON_API_KEY}" \
  --data-urlencode "q=-label:Triage/Processed is:inbox newer_than:30d" \
  --data-urlencode "maxResults=50" \
  "${MATON_BASE}/messages" \
  2>/dev/null || echo '{}')

EMAIL_IDS=$(echo "$EMAIL_IDS_JSON" | jq -r '.messages[]?.id // empty')
EMAIL_COUNT=$(echo "$EMAIL_IDS" | grep -c . 2>/dev/null || echo 0)

if [ -z "$EMAIL_IDS" ]; then
  log "info" "No new emails to process" "{\"fetched\":0}"
  exit 0
fi

log "info" "Emails fetched" "{\"count\":$EMAIL_COUNT}"

# ── Process each email via Lobster workflow ──────────────────────────
# lobster run is the proven shell binary invocation (v2.4+).
# Each run produces its own structured output captured by this script
# and tee'd to the log file, which is visible in the agent session.
COUNT=0
ERRORS=0
RESULTS="[]"

for EMAIL_ID in $EMAIL_IDS; do
  log "info" "Processing email" "{\"email_id\":\"$EMAIL_ID\"}"

  if OUTPUT=$(lobster run \
       --file "$WORKFLOW" \
       --args-json "{\"email_id\":\"$EMAIL_ID\"}" 2>&1); then

    # Extract action_taken from Lobster's final step stdout if available
    ACTION=$(echo "$OUTPUT" | grep -o '"action_taken":"[^"]*"' | tail -1 | cut -d'"' -f4 || echo "unknown")
    BUCKET=$(echo "$OUTPUT" | grep -o '"bucket":"[^"]*"' | tail -1 | cut -d'"' -f4 || echo "unknown")

    log "info" "Email processed" \
      "{\"email_id\":\"$EMAIL_ID\",\"bucket\":\"$BUCKET\",\"action\":\"$ACTION\"}"

    RESULTS=$(echo "$RESULTS" | jq \
      --arg id "$EMAIL_ID" --arg bucket "$BUCKET" --arg action "$ACTION" \
      '. + [{id:$id,bucket:$bucket,action:$action,status:"ok"}]')
    COUNT=$((COUNT + 1))
  else
    log "error" "Email processing failed" \
      "{\"email_id\":\"$EMAIL_ID\",\"error\":$(echo "$OUTPUT" | tail -1 | jq -Rs .)}"

    RESULTS=$(echo "$RESULTS" | jq \
      --arg id "$EMAIL_ID" \
      '. + [{id:$id,status:"error"}]')
    ERRORS=$((ERRORS + 1))
  fi
done

# ── Final summary (agent reads this from exec output) ────────────────
SUMMARY=$(jq -n \
  --argjson count "$COUNT" \
  --argjson errors "$ERRORS" \
  --argjson results "$RESULTS" \
  '{processed:$count,errors:$errors,results:$results}')

log "info" "Triage run complete" "$SUMMARY"

# Print summary to stdout so the agent can read it and report if needed
echo "$SUMMARY"

# Exit non-zero if any errors so the agent session notes the failure
[ "$ERRORS" -eq 0 ] || exit 1
