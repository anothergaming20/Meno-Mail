#!/usr/bin/env bash
# send-approved-reply.sh — Send approved Gmail draft after Telegram approval. (v2.5)
# v2.5: Gmail calls via Maton API Gateway (MATON_API_KEY bearer token).
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

EMAIL_ID="$1"
DRAFTS_FILE="${DRAFTS_FILE:-$HOME/.openclaw/workspace/data/pending-drafts.json}"
MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

# Retrieve stored draft metadata
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
  curl -sf -X POST \
    -H "Authorization: Bearer ${MATON_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg did "$GMAIL_DRAFT_ID" '{id:$did}')" \
    "${MATON_BASE}/drafts/send"
else
  # Fallback: build and send raw message
  RAW_MSG=$(printf "To: %s\r\nSubject: Re: %s\r\nIn-Reply-To: %s\r\nReferences: %s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s" \
    "$FROM_ADDR" "$SUBJECT" "$EMAIL_ID" "$EMAIL_ID" "$DRAFT")
  ENCODED_MSG=$(echo -n "$RAW_MSG" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
  curl -sf -X POST \
    -H "Authorization: Bearer ${MATON_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg raw "$ENCODED_MSG" --arg tid "$EMAIL_ID" \
      '{raw: $raw, threadId: $tid}')" \
    "${MATON_BASE}/messages/send"
fi

# Apply Approved label
LABEL_IDS_FILE="${LABEL_IDS_FILE:-$HOME/.openclaw/workspace/data/label-ids.env}"
[ -f "$LABEL_IDS_FILE" ] && source "$LABEL_IDS_FILE"
APPROVED_LABEL="${LABEL_TRIAGE_APPROVED:-Triage/Approved}"

curl -sf -X POST \
  -H "Authorization: Bearer ${MATON_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg lid "$APPROVED_LABEL" '{addLabelIds:[$lid]}')" \
  "${MATON_BASE}/messages/${EMAIL_ID}/modify" >/dev/null

# Remove draft from pending store
jq --arg id "$EMAIL_ID" 'del(.[$id])' "$DRAFTS_FILE" > "${DRAFTS_FILE}.tmp" \
  && mv "${DRAFTS_FILE}.tmp" "$DRAFTS_FILE"

echo "{\"status\": \"sent\", \"email_id\": \"${EMAIL_ID}\"}"
