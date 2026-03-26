#!/usr/bin/env bash
# fetch-email.sh — Fetch a single email via Maton API Gateway. (v2.5)
# Outputs structured JSON: email_id, thread_id, message_id, from, to,
# subject, date, body_text (truncated to 3000 chars).
#
# v2.5 changes vs v2.4:
# - gws CLI replaced with Maton API Gateway (MATON_API_KEY bearer token)
# - Endpoint: https://gateway.maton.ai/google-mail/gmail/v1/users/me/messages/<id>

set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

EMAIL_ID="$1"
MAX_BODY_CHARS=3000
MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

RAW=$(curl -sf \
  -H "Authorization: Bearer ${MATON_API_KEY}" \
  "${MATON_BASE}/messages/${EMAIL_ID}?format=full")

echo "$RAW" | jq --arg max "$MAX_BODY_CHARS" '{
  email_id: .id,
  thread_id: .threadId,
  message_id: ((.payload.headers // [])[] | select(.name == "Message-ID" or .name == "Message-Id") | .value),
  from: ((.payload.headers // [])[] | select(.name == "From") | .value),
  to: ((.payload.headers // [])[] | select(.name == "To") | .value),
  subject: ((.payload.headers // [])[] | select(.name == "Subject") | .value),
  date: ((.payload.headers // [])[] | select(.name == "Date") | .value),
  body_text: ((.snippet // "")[0:($max | tonumber)])
}'
