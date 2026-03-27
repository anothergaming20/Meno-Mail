#!/bin/bash
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

EMAIL_ID="${1:-}"
FULL_BODY="${2:-}"  # Pass --full-body for newsletter extraction

if [ -z "$EMAIL_ID" ]; then
  echo "[fetch-email] ERROR: No email ID provided." >&2
  exit 1
fi

MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

RESPONSE=$(curl -sf -H "Authorization: Bearer $MATON_API_KEY" \
  "$MATON_BASE/messages/${EMAIL_ID}?format=full" || true)

if [ -z "$RESPONSE" ]; then
  echo "[fetch-email] ERROR: Empty response for message $EMAIL_ID" >&2
  exit 1
fi

# ── Extract headers ─────────────────────────────────────────────────────────
FROM=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "From") | .value
' 2>/dev/null | head -1 || echo "")

TO=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "To") | .value
' 2>/dev/null | head -1 || echo "")

SUBJECT=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "Subject") | .value
' 2>/dev/null | head -1 || echo "")

DATE=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "Date") | .value
' 2>/dev/null | head -1 || echo "")

MESSAGE_ID_HEADER=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "Message-ID") | .value
' 2>/dev/null | head -1 || echo "")

# ── Bulk signal detection for Gate 0 ────────────────────────────────────────
LIST_UNSUBSCRIBE=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "List-Unsubscribe") | .value
' 2>/dev/null | head -1 || echo "")

PRECEDENCE=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "Precedence") | .value
' 2>/dev/null | head -1 || echo "")

X_MAILER=$(echo "$RESPONSE" | jq -r '
  .payload.headers[] | select(.name == "X-Mailer") | .value
' 2>/dev/null | head -1 || echo "")

# ── Extract body text ────────────────────────────────────────────────────────
# Try plain text part first, fall back to snippet
BODY_B64=$(echo "$RESPONSE" | jq -r '
  def find_text:
    if .mimeType == "text/plain" then .body.data // ""
    elif .parts? then (.parts[] | find_text)
    else ""
    end;
  .payload | find_text
' 2>/dev/null | head -1 || echo "")

if [ -n "$BODY_B64" ]; then
  # macOS base64 uses -D flag for decode, and Gmail uses URL-safe base64
  BODY_TEXT=$(echo "$BODY_B64" | tr '_-' '/+' | base64 -d 2>/dev/null || echo "")
else
  BODY_TEXT=$(echo "$RESPONSE" | jq -r '.snippet // ""' 2>/dev/null || echo "")
fi

# Truncate to 3000 chars unless --full-body requested
if [ "$FULL_BODY" != "--full-body" ]; then
  BODY_TEXT="${BODY_TEXT:0:3000}"
fi

THREAD_ID=$(echo "$RESPONSE" | jq -r '.threadId // ""' 2>/dev/null || echo "")
LABEL_IDS=$(echo "$RESPONSE" | jq -c '.labelIds // []' 2>/dev/null || echo "[]")
INTERNAL_DATE=$(echo "$RESPONSE" | jq -r '.internalDate // ""' 2>/dev/null || echo "")

# ── Detect forwarded message ─────────────────────────────────────────────────
FWD_DATA=$(python3 -c "
import sys, json, re
body = sys.stdin.read()
patterns = [
    r'[-]{5,}\s*Forwarded message\s*[-]{5,}',
    r'Begin forwarded message:',
    r'-----Original Message-----',
    r'_{5,}\s*From:',
]
is_fwd = False
fwd_from = ''
fwd_subject = ''
for p in patterns:
    m = re.search(p, body, re.IGNORECASE)
    if m:
        is_fwd = True
        tail = body[m.end():]
        mf = re.search(r'From:\s*(.+)', tail, re.IGNORECASE)
        if mf:
            fwd_from = mf.group(1).strip()
        ms = re.search(r'Subject:\s*(.+)', tail, re.IGNORECASE)
        if ms:
            fwd_subject = ms.group(1).strip()
        break
print(json.dumps({'is_forwarded': is_fwd, 'forwarded_from': fwd_from, 'forwarded_subject': fwd_subject}))
" <<< "$BODY_TEXT" 2>/dev/null || echo '{"is_forwarded":false,"forwarded_from":"","forwarded_subject":""}')

IS_FORWARDED=$(echo "$FWD_DATA" | jq -r '.is_forwarded' 2>/dev/null || echo "false")
FORWARDED_FROM=$(echo "$FWD_DATA" | jq -r '.forwarded_from' 2>/dev/null || echo "")
FORWARDED_SUBJECT=$(echo "$FWD_DATA" | jq -r '.forwarded_subject' 2>/dev/null || echo "")

# ── Output as JSON (safe — all content via jq --arg) ─────────────────────────
jq -n \
  --arg msg_id "$EMAIL_ID" \
  --arg thread_id "$THREAD_ID" \
  --arg message_id_header "$MESSAGE_ID_HEADER" \
  --arg from "$FROM" \
  --arg to "$TO" \
  --arg subject "$SUBJECT" \
  --arg date "$DATE" \
  --arg body_text "$BODY_TEXT" \
  --arg list_unsubscribe "$LIST_UNSUBSCRIBE" \
  --arg precedence "$PRECEDENCE" \
  --arg x_mailer "$X_MAILER" \
  --arg internal_date "$INTERNAL_DATE" \
  --argjson label_ids "$LABEL_IDS" \
  --argjson is_forwarded "$IS_FORWARDED" \
  --arg forwarded_from "$FORWARDED_FROM" \
  --arg forwarded_subject "$FORWARDED_SUBJECT" \
  '{
    msg_id: $msg_id,
    thread_id: $thread_id,
    message_id_header: $message_id_header,
    from: $from,
    to: $to,
    subject: $subject,
    date: $date,
    body_text: $body_text,
    label_ids: $label_ids,
    internal_date: $internal_date,
    is_forwarded: $is_forwarded,
    forwarded_from: $forwarded_from,
    forwarded_subject: $forwarded_subject,
    bulk_signals: {
      list_unsubscribe: ($list_unsubscribe != ""),
      precedence_bulk: ($precedence | test("bulk|list"; "i")),
      x_mailer_bulk: ($x_mailer | test("mailchimp|sendgrid|marketo|hubspot|constant.contact|klaviyo"; "i"))
    }
  }'
