#!/usr/bin/env bash
# send-approved-reply.sh — Send the approved draft reply via Gmail.
# Only runs after human approval via Telegram inline button.
set -euo pipefail

EMAIL_ID="$1"
DRAFTS_FILE="${DRAFTS_FILE:-$HOME/.openclaw/workspace/data/pending-drafts.json}"

# Retrieve stored draft
DRAFT=$(jq -r --arg id "$EMAIL_ID" '.[$id].draft // empty' "$DRAFTS_FILE")
if [ -z "$DRAFT" ]; then
  echo "ERROR: No draft found for message $EMAIL_ID" >&2
  exit 1
fi

FROM_ADDR=$(jq -r --arg id "$EMAIL_ID" '.[$id].from // empty' "$DRAFTS_FILE")
SUBJECT=$(jq -r --arg id "$EMAIL_ID" '.[$id].subject // empty' "$DRAFTS_FILE")
GMAIL_DRAFT_ID=$(jq -r --arg id "$EMAIL_ID" '.[$id].gmail_draft_id // empty' "$DRAFTS_FILE")

if [ -n "$GMAIL_DRAFT_ID" ]; then
  # Send via Gmail drafts.send (preserves threading)
  gws gmail users drafts send \
    --params '{"userId":"me"}' \
    --json "$(jq -n --arg did "$GMAIL_DRAFT_ID" '{id:$did}')"
else
  # Fallback: build and send raw message
  RAW_MSG=$(printf "To: %s\r\nSubject: Re: %s\r\nIn-Reply-To: %s\r\nReferences: %s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s" \
    "$FROM_ADDR" "$SUBJECT" "$EMAIL_ID" "$EMAIL_ID" "$DRAFT")
  ENCODED_MSG=$(echo -n "$RAW_MSG" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
  gws gmail users messages send \
    --params '{"userId":"me"}' \
    --json "$(jq -n --arg raw "$ENCODED_MSG" --arg tid "$EMAIL_ID" \
      '{raw: $raw, threadId: $tid}')"
fi

# Apply Approved label
LABEL_IDS_FILE="${LABEL_IDS_FILE:-$HOME/.openclaw/workspace/data/label-ids.env}"
if [ -f "$LABEL_IDS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$LABEL_IDS_FILE"
fi
APPROVED_LABEL="${LABEL_TRIAGE_APPROVED:-Triage/Approved}"

gws gmail users messages modify \
  --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')" \
  --json "$(jq -n --arg lid "$APPROVED_LABEL" '{addLabelIds:[$lid]}')"

# Remove draft from pending store
jq --arg id "$EMAIL_ID" 'del(.[$id])' "$DRAFTS_FILE" > "${DRAFTS_FILE}.tmp" \
  && mv "${DRAFTS_FILE}.tmp" "$DRAFTS_FILE"

echo '{"status": "sent", "email_id": "'"$EMAIL_ID"'"}'
