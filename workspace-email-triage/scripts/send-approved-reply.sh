#!/bin/bash
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
PENDING_DRAFTS="$DATA_DIR/pending-drafts.json"
LABEL_IDS_FILE="$DATA_DIR/label-ids.env"

EMAIL_ID="${1:-}"

if [ -z "$EMAIL_ID" ]; then
  echo "[send-approved-reply] ERROR: No email ID provided." >&2
  exit 1
fi

# Load label IDs
if [ -f "$LABEL_IDS_FILE" ]; then
  source "$LABEL_IDS_FILE"
fi

# Get draft entry
DRAFT_ENTRY=$(jq -r --arg key "$EMAIL_ID" '.[$key] // empty' "$PENDING_DRAFTS" 2>/dev/null || echo "")

if [ -z "$DRAFT_ENTRY" ]; then
  echo "[send-approved-reply] ERROR: No pending draft found for $EMAIL_ID" >&2
  exit 1
fi

GMAIL_DRAFT_ID=$(echo "$DRAFT_ENTRY" | jq -r '.gmail_draft_id // ""' 2>/dev/null || echo "")

if [ -z "$GMAIL_DRAFT_ID" ]; then
  echo "[send-approved-reply] ERROR: No Gmail draft ID for $EMAIL_ID" >&2
  exit 1
fi

MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

# Send the draft via Maton API
SEND_BODY=$(jq -n --arg id "$GMAIL_DRAFT_ID" '{"id": $id}')

SEND_RESP_FILE=$(mktemp)
HTTP_CODE=$(curl -s -o "$SEND_RESP_FILE" -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $MATON_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$SEND_BODY" \
  "$MATON_BASE/drafts/send" 2>/dev/null || echo "000")
SEND_RESPONSE=$(cat "$SEND_RESP_FILE" 2>/dev/null || echo "")
rm -f "$SEND_RESP_FILE"

if [ "$HTTP_CODE" != "200" ]; then
  echo "[send-approved-reply] ERROR: HTTP $HTTP_CODE when sending draft $GMAIL_DRAFT_ID — $SEND_RESPONSE" >&2
  exit 1
fi

# Apply Triage/Approved label
if [ -n "${LABEL_TRIAGE_APPROVED:-}" ]; then
  MODIFY_BODY=$(jq -n \
    --arg label_id "$LABEL_TRIAGE_APPROVED" \
    '{"addLabelIds": [$label_id]}')

  curl -sf -X POST \
    -H "Authorization: Bearer $MATON_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$MODIFY_BODY" \
    "$MATON_BASE/messages/${EMAIL_ID}/modify" > /dev/null || true
fi

# Remove from pending-drafts.json
CURRENT_DRAFTS=$(cat "$PENDING_DRAFTS" 2>/dev/null || echo "{}")
echo "$CURRENT_DRAFTS" | jq \
  --arg key "$EMAIL_ID" \
  'del(.[$key])' > "${PENDING_DRAFTS}.tmp" && \
  mv "${PENDING_DRAFTS}.tmp" "$PENDING_DRAFTS"

echo "[send-approved-reply] Sent draft for $EMAIL_ID, labeled Triage/Approved"
