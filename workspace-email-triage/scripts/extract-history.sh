#!/bin/bash
set -euo pipefail
# extract-history.sh — Pull last 2 days of email metadata from Maton API
# Output: ~/.openclaw/workspace-email-triage/data/email-history.jsonl (append, idempotent)

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
HISTORY_FILE="$DATA_DIR/email-history.jsonl"
MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

mkdir -p "$DATA_DIR"

# ── Build temp set of already-seen IDs (idempotency) ─────────────────────
SEEN_FILE=$(mktemp)
trap 'rm -f "$SEEN_FILE"' EXIT

if [ -f "$HISTORY_FILE" ]; then
  jq -r '.msg_id' "$HISTORY_FILE" 2>/dev/null > "$SEEN_FILE" || true
fi
EXISTING=$(wc -l < "$SEEN_FILE" | tr -d ' ')
echo "[extract-history] Already have $EXISTING entries. Fetching last 2 days..." >&2

# ── Paginate messages.list ────────────────────────────────────────────────
PAGE_TOKEN=""
NEW_COUNT=0
TOTAL_COUNT=0

while true; do
  URL="${MATON_BASE}/messages?q=newer_than%3A2d&maxResults=100"
  [ -n "$PAGE_TOKEN" ] && URL="${URL}&pageToken=${PAGE_TOKEN}"

  LIST_RESP=$(curl -sf \
    -H "Authorization: Bearer $MATON_API_KEY" \
    "$URL" 2>/dev/null || echo "")

  if [ -z "$LIST_RESP" ]; then
    echo "[extract-history] ERROR: Empty response from messages.list" >&2
    break
  fi

  MSG_IDS=$(echo "$LIST_RESP" | jq -r '.messages[]?.id // empty' 2>/dev/null || true)
  if [ -z "$MSG_IDS" ]; then
    break
  fi

  while IFS= read -r MSG_ID; do
    [ -z "$MSG_ID" ] && continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    # Skip if already stored
    if grep -qxF "$MSG_ID" "$SEEN_FILE" 2>/dev/null; then
      continue
    fi

    # Fetch message metadata only (fast — no body).
    # Maton gateway does not support metadataHeaders filter — omit it.
    META=$(curl -sf \
      -H "Authorization: Bearer $MATON_API_KEY" \
      "${MATON_BASE}/messages/${MSG_ID}?format=metadata" \
      2>/dev/null || echo "")

    [ -z "$META" ] && continue

    FROM=$(echo "$META" | jq -r '
      .payload.headers[] | select(.name == "From") | .value
    ' 2>/dev/null | head -1 || echo "")

    SUBJECT=$(echo "$META" | jq -r '
      .payload.headers[] | select(.name == "Subject") | .value
    ' 2>/dev/null | head -1 || echo "")

    LIST_UNSUB=$(echo "$META" | jq -r '
      .payload.headers[] | select(.name == "List-Unsubscribe") | .value
    ' 2>/dev/null | head -1 || echo "")

    THREAD_ID=$(echo "$META" | jq -r '.threadId // ""' 2>/dev/null || echo "")
    INTERNAL_MS=$(echo "$META" | jq -r '.internalDate // "0"' 2>/dev/null || echo "0")
    SNIPPET=$(echo "$META" | jq -r '.snippet // ""' 2>/dev/null || echo "")
    LABEL_IDS=$(echo "$META" | jq -c '.labelIds // []' 2>/dev/null || echo "[]")

    # Extract sender email and domain from From header
    SENDER_EMAIL=$(echo "$FROM" | \
      perl -ne 'if (/<([^>@\s]+@[^>\s]+)>/) { print "$1\n"; last }
                elsif (/(\S+@\S+\.\S+)/)    { print "$1\n"; last }' \
      2>/dev/null | head -1 || echo "")
    SENDER_DOMAIN=$(echo "$SENDER_EMAIL" | awk -F@ '{print tolower($2)}' 2>/dev/null || echo "")

    # Convert millisecond epoch to ISO 8601
    DATE_ISO=$(python3 -c "
import datetime
ms = int('${INTERNAL_MS}' or 0)
print(datetime.datetime.utcfromtimestamp(ms/1000).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || echo "")

    HAS_UNSUB="false"
    [ -n "$LIST_UNSUB" ] && HAS_UNSUB="true"

    # Append JSONL line — all values safe via jq --arg / --argjson
    jq -cn \
      --arg msg_id           "$MSG_ID" \
      --arg thread_id        "$THREAD_ID" \
      --arg from             "$FROM" \
      --arg subject          "$SUBJECT" \
      --arg date             "$DATE_ISO" \
      --argjson labels       "$LABEL_IDS" \
      --arg sender_domain    "$SENDER_DOMAIN" \
      --argjson has_unsubscribe "$HAS_UNSUB" \
      --arg snippet          "$SNIPPET" \
      '{msg_id:$msg_id, thread_id:$thread_id, from:$from, subject:$subject,
        date:$date, labels:$labels, sender_domain:$sender_domain,
        has_unsubscribe:$has_unsubscribe, snippet:$snippet}' \
      >> "$HISTORY_FILE"

    echo "$MSG_ID" >> "$SEEN_FILE"
    NEW_COUNT=$((NEW_COUNT + 1))

  done <<< "$MSG_IDS"

  PAGE_TOKEN=$(echo "$LIST_RESP" | jq -r '.nextPageToken // ""' 2>/dev/null || echo "")
  [ -z "$PAGE_TOKEN" ] && break
done

TOTAL_LINES=$(wc -l < "$HISTORY_FILE" 2>/dev/null | tr -d ' ' || echo "0")
echo "[extract-history] Done. Scanned $TOTAL_COUNT messages, added $NEW_COUNT new. Total: $TOTAL_LINES entries." >&2
