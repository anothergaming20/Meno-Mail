#!/bin/bash
set -euo pipefail
# ingest-email.sh — Gate 0 + Gate 1 routing to Branch A/B/C
# Phase 4 full implementation. Phase 1: stub that routes newsletters to background job.

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

# Read email JSON from stdin
INPUT_JSON=$(cat)
EMAIL_ID=$(echo "$INPUT_JSON" | jq -r '.msg_id // ""' 2>/dev/null || echo "")
BUCKET=""

# Check classification if available in piped context
# (In Phase 1 the ingest step gets raw email from fetch_message)
FROM=$(echo "$INPUT_JSON" | jq -r '.from // ""' 2>/dev/null || echo "")

# ── Gate 0: Header-based bulk signal detection ─────────────────────────────
LIST_UNSUBSCRIBE=$(echo "$INPUT_JSON" | jq -r '.bulk_signals.list_unsubscribe // false' 2>/dev/null || echo "false")
PRECEDENCE_BULK=$(echo "$INPUT_JSON" | jq -r '.bulk_signals.precedence_bulk // false' 2>/dev/null || echo "false")
XMAILER_BULK=$(echo "$INPUT_JSON" | jq -r '.bulk_signals.x_mailer_bulk // false' 2>/dev/null || echo "false")

BULK_SIGNAL_COUNT=0
[ "$LIST_UNSUBSCRIBE" = "true" ] && BULK_SIGNAL_COUNT=$((BULK_SIGNAL_COUNT + 1))
[ "$PRECEDENCE_BULK" = "true" ] && BULK_SIGNAL_COUNT=$((BULK_SIGNAL_COUNT + 1))
[ "$XMAILER_BULK" = "true" ] && BULK_SIGNAL_COUNT=$((BULK_SIGNAL_COUNT + 1))

if [ "$BULK_SIGNAL_COUNT" -ge 2 ]; then
  GATE0_RESULT="bulk_candidate"
else
  GATE0_RESULT="human_candidate"
fi

IS_FORWARDED=$(echo "$INPUT_JSON" | jq -r '.is_forwarded // false' 2>/dev/null || echo "false")

echo "[ingest-email] Email $EMAIL_ID — Gate 0: $GATE0_RESULT (bulk signals: $BULK_SIGNAL_COUNT, forwarded: $IS_FORWARDED)" >&2

# ── Route to branch ─────────────────────────────────────────────────────────
if [ "$GATE0_RESULT" = "bulk_candidate" ] || [ "$IS_FORWARDED" = "true" ]; then
  # Branch B: newsletter extraction (background job — does not block triage)
  # Forwarded emails may contain newsletter articles even if outer sender is human
  echo "[ingest-email] Routing to Branch B (newsletter/forwarded) — background job" >&2
  lobster run \
    --file "$HOME/.openclaw/workspace-email-triage/workflows/newsletter-extract.lobster" \
    --args-json "{\"email_id\":\"$EMAIL_ID\"}" &
else
  # Branch A: human correspondence — Phase 4 full pipeline
  # Phase 1 stub: log only
  echo "[ingest-email] Branch A (human) — Phase 4 full pipeline deferred" >&2
fi

# Always output the input for downstream steps
echo "$INPUT_JSON"
