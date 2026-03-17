#!/usr/bin/env bash
# fetch-email.sh — Fetch a single email by ID and output structured JSON.
# Truncates body to 3000 chars to stay within context budget.
set -euo pipefail

EMAIL_ID="$1"
MAX_BODY_CHARS=3000

# Fetch full message via gws (personal Gmail uses userId: "me")
RAW=$(gws gmail users messages get \
  --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id,format:"full"}')")

# Extract fields and truncate body
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
