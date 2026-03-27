#!/bin/bash
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
LABEL_IDS_FILE="$DATA_DIR/label-ids.env"

EMAIL_ID="${1:-}"

# Read classification JSON from stdin (pass-through)
INPUT_JSON=$(cat)

if [ -z "$EMAIL_ID" ]; then
  # Try to get it from stdin JSON
  EMAIL_ID=$(echo "$INPUT_JSON" | jq -r '.email.msg_id // ""' 2>/dev/null || echo "")
fi

if [ -z "$EMAIL_ID" ]; then
  echo "[mark-processed] ERROR: No email ID provided." >&2
  echo "$INPUT_JSON"  # pass through
  exit 1
fi

# Load label IDs
PROCESSED_LABEL_ID=""
if [ -f "$LABEL_IDS_FILE" ]; then
  source "$LABEL_IDS_FILE"
  PROCESSED_LABEL_ID="${LABEL_TRIAGE_PROCESSED:-}"
fi

if [ -z "$PROCESSED_LABEL_ID" ]; then
  echo "[mark-processed] WARNING: No Triage/Processed label ID found. Skipping label application." >&2
  echo "$INPUT_JSON"
  exit 0
fi

MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

# Apply Triage/Processed label via Maton API (safe via jq --arg)
MODIFY_BODY=$(jq -n \
  --arg label_id "$PROCESSED_LABEL_ID" \
  '{"addLabelIds": [$label_id]}')

curl -sf -X POST \
  -H "Authorization: Bearer $MATON_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$MODIFY_BODY" \
  "$MATON_BASE/messages/${EMAIL_ID}/modify" > /dev/null

echo "[mark-processed] Applied Triage/Processed to $EMAIL_ID" >&2

# Pass JSON through unchanged
echo "$INPUT_JSON"
