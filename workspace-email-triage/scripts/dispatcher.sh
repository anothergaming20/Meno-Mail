#!/bin/bash
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
MEMORY_DIR="$WORKSPACE_TRIAGE/memory"

LOCKFILE="/tmp/menomail-dispatcher.lock"
MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

# ── Lockfile guard ──────────────────────────────────────────────────────────
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "[dispatcher] Already running (pid $LOCK_PID). Skipping." >&2
    exit 0
  else
    echo "[dispatcher] Stale lockfile found. Removing." >&2
    rm -f "$LOCKFILE"
  fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

echo "[dispatcher] Starting triage run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Fetch unprocessed messages ───────────────────────────────────────────────
RESPONSE=$(curl -sf -H "Authorization: Bearer $MATON_API_KEY" \
  "$MATON_BASE/messages?q=-label:Triage%2FProcessed+is:inbox+newer_than:30d&maxResults=50" || true)

if [ -z "$RESPONSE" ]; then
  echo "[dispatcher] No response from Maton API. Exiting." >&2
  exit 1
fi

MESSAGE_IDS=$(echo "$RESPONSE" | jq -r '.messages[]?.id // empty' 2>/dev/null || true)

if [ -z "$MESSAGE_IDS" ]; then
  echo "[dispatcher] No unprocessed messages found."
  exit 0
fi

COUNT=0
while IFS= read -r EMAIL_ID; do
  [ -z "$EMAIL_ID" ] && continue
  echo "[dispatcher] Processing email: $EMAIL_ID"

  # ── Pre-triage sender lookup (jq on sender-preferences.json) ──────────────
  # Fetch minimal headers first to get sender address
  HEADERS=$(curl -sf -H "Authorization: Bearer $MATON_API_KEY" \
    "$MATON_BASE/messages/${EMAIL_ID}?format=metadata" || true)

  FROM_ADDRESS=""
  if [ -n "$HEADERS" ]; then
    FROM_ADDRESS=$(echo "$HEADERS" | jq -r '
      .payload.headers[]? | select(.name == "From") | .value
    ' 2>/dev/null | perl -ne 'if (/([\w.+%-]+@[\w.-]+\.[a-zA-Z]{2,})/) { print "$1\n" }' | head -1 || true)
  fi

  SENDER_ACTION=""
  if [ -n "$FROM_ADDRESS" ] && [ -f "$DATA_DIR/sender-preferences.json" ]; then
    SENDER_ACTION=$(jq -r --arg s "$FROM_ADDRESS" \
      '.[] | select(.sender == $s) | .action' \
      "$DATA_DIR/sender-preferences.json" 2>/dev/null | head -1 || true)
  fi

  if [ -n "$SENDER_ACTION" ]; then
    echo "[dispatcher] Sender $FROM_ADDRESS pre-classified as: $SENDER_ACTION"
    # Inject pre-classified verdict — skip LLM, run workflow with hint
    lobster run \
      --file "$HOME/.openclaw/workspace-email-triage/workflows/email-triage.lobster" \
      --args-json "{\"email_id\":\"$EMAIL_ID\",\"pre_classified_action\":\"$SENDER_ACTION\"}" \
      2>&1 || echo "[dispatcher] Workflow error for $EMAIL_ID (pre-classified)" >&2
  else
    lobster run \
      --file "$HOME/.openclaw/workspace-email-triage/workflows/email-triage.lobster" \
      --args-json "{\"email_id\":\"$EMAIL_ID\",\"pre_classified_action\":\"\"}" \
      2>&1 || echo "[dispatcher] Workflow error for $EMAIL_ID" >&2
  fi

  COUNT=$((COUNT + 1))
done <<< "$MESSAGE_IDS"

echo "[dispatcher] Done. Processed $COUNT email(s)."

# ── Push updated digest to Fly.io mini app ────────────────────────────────
if [ "$COUNT" -gt 0 ]; then
  bash "$SCRIPT_DIR/build-and-push-digest.sh" 2>&1 || \
    echo "[dispatcher] WARNING: digest push failed" >&2

  # ── Send Telegram run summary with mini app button ─────────────────────
  BOT_TOKEN=$(cat ~/.openclaw/secrets/telegram-bot-token 2>/dev/null || echo "$TELEGRAM_BOT_TOKEN")
  CHAT_ID=$(cat ~/.openclaw/secrets/telegram-chat-id 2>/dev/null || echo "$TELEGRAM_CHAT_ID")

  if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
    PENDING_COUNT=$(python3 -c "
import json; from pathlib import Path
p = Path.home()/'.openclaw'/'workspace-email-triage'/'data'/'pending-drafts.json'
try: print(len(json.loads(p.read_text())))
except: print(0)
" 2>/dev/null || echo "0")

    TG_PAYLOAD=$(python3 -c "
import json, sys
chat_id = sys.argv[1]
pending = int(sys.argv[2])
processed = sys.argv[3]
if pending > 0:
    msg = f'📬 <b>Triage complete</b>\n\n{processed} email(s) processed · {pending} draft(s) waiting for review.'
    button_text = '📋 Review drafts →'
    screen = '?screen=review'
else:
    msg = f'📬 <b>Triage complete</b>\n\n{processed} email(s) processed · inbox clean.'
    button_text = '📬 Open inbox →'
    screen = ''
payload = {
  'chat_id': chat_id,
  'text': msg,
  'parse_mode': 'HTML',
  'reply_markup': {
    'inline_keyboard': [[
      {'text': button_text, 'web_app': {'url': 'https://menomail.fly.dev/' + screen}}
    ]]
  }
}
print(json.dumps(payload))
" "$CHAT_ID" "$PENDING_COUNT" "$COUNT" 2>/dev/null)

    curl -sf -X POST \
      "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$TG_PAYLOAD" > /dev/null 2>&1 || true
  fi
fi
