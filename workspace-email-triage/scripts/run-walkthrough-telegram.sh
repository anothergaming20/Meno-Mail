#!/bin/bash
set -euo pipefail
# run-walkthrough-telegram.sh — Drive the sender-labeling walkthrough via Telegram.
#
# ARCHITECTURE:
#   This script sends sender cards to Telegram and waits for responses.
#   Responses arrive via two paths (tried in order):
#     1. walkthrough-callbacks.jsonl — written by OpenClaw's main agent when it
#        receives a "walk:ACTION:SENDER" callback_query. Preferred path.
#     2. Direct Telegram getUpdates polling — fallback if main agent is not
#        configured or misses a callback.
#
#   The main agent writes callbacks via its AGENTS.md instructions.
#   See ~/.openclaw/agents/main/agent/AGENTS.md.

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"

SESSION_FILE="$DATA_DIR/walkthrough-session.json"
CALLBACKS_FILE="$DATA_DIR/walkthrough-callbacks.jsonl"
PREFS_FILE="$DATA_DIR/sender-preferences.json"

BOT_TOKEN=$(cat ~/.openclaw/secrets/telegram-bot-token 2>/dev/null || echo "$TELEGRAM_BOT_TOKEN")
CHAT_ID=$(cat ~/.openclaw/secrets/telegram-chat-id 2>/dev/null || echo "$TELEGRAM_CHAT_ID")
TG_API="https://api.telegram.org/bot${BOT_TOKEN}"

TIMEOUT_SECS=180  # wait up to 3 minutes per card before retrying

if [ ! -f "$SESSION_FILE" ]; then
  echo "[walkthrough] ERROR: $SESSION_FILE not found. Run prepare-walkthrough.sh first." >&2
  exit 1
fi

TOTAL=$(python3 -c "import json; s=json.load(open('$SESSION_FILE')); print(s['total_senders'])")
if [ "$TOTAL" -eq 0 ]; then
  echo "[walkthrough] No senders to label. Session is empty." >&2
  exit 0
fi

echo "[walkthrough] Starting walkthrough: $TOTAL senders to label." >&2
echo "[walkthrough] Respond to Telegram messages with the action buttons." >&2

# ── Helper: send a plain Telegram message ────────────────────────────────
tg_send() {
  local text="$1"
  curl -sf -X POST "$TG_API/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat_id "$CHAT_ID" --arg text "$text" \
          '{chat_id:$chat_id, text:$text}')" \
    > /dev/null || true
}

# ── Helper: send a sender card with action buttons ───────────────────────
send_card() {
  local sender="$1"
  local domain="$2"
  local subject="$3"
  local count="$4"
  local idx="$5"    # 1-based
  local total="$6"

  local TEXT
  TEXT=$(printf "Sender %d of %d\n\n📨 %s\n🌐 %s\n📋 %s\n📊 %d email(s)" \
    "$idx" "$total" "$sender" "$domain" "$subject" "$count")

  # Encode sender for callback_data (replace @ and . with safe chars)
  # callback_data max 64 bytes — use a session index instead of full email
  local ENCODED_IDX
  ENCODED_IDX=$(printf "%04d" "$idx")

  jq -cn \
    --arg chat_id "$CHAT_ID" \
    --arg text "$TEXT" \
    --arg cd_del    "walk:delete:${ENCODED_IDX}" \
    --arg cd_arc    "walk:archive:${ENCODED_IDX}" \
    --arg cd_scan   "walk:scan:${ENCODED_IDX}" \
    --arg cd_read   "walk:deep_read:${ENCODED_IDX}" \
    --arg cd_imp    "walk:important:${ENCODED_IDX}" \
    --arg cd_skip   "walk:skip:${ENCODED_IDX}" \
    '{chat_id:$chat_id, text:$text, reply_markup:{
       inline_keyboard:[
         [
           {text:"🗑 Delete",    callback_data:$cd_del},
           {text:"📦 Archive",   callback_data:$cd_arc},
           {text:"👁 Scan",      callback_data:$cd_scan}
         ],
         [
           {text:"📖 Read",      callback_data:$cd_read},
           {text:"⚡ Important", callback_data:$cd_imp},
           {text:"⏭ Skip",      callback_data:$cd_skip}
         ]
       ]
     }}' \
  | curl -sf -X POST "$TG_API/sendMessage" \
      -H "Content-Type: application/json" \
      -d @- 2>/dev/null | jq -r '.result.message_id' 2>/dev/null || echo ""
}

# ── Helper: delete a Telegram message (remove old cards) ─────────────────
delete_msg() {
  local msg_id="$1"
  [ -z "$msg_id" ] && return
  curl -sf -X POST "$TG_API/deleteMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat_id "$CHAT_ID" --argjson msg_id "$msg_id" \
          '{chat_id:$chat_id, message_id:$msg_id}')" \
    > /dev/null 2>&1 || true
}

# ── Helper: poll for a callback response ─────────────────────────────────
# First checks walkthrough-callbacks.jsonl (written by OpenClaw main agent),
# then falls back to direct getUpdates polling.
wait_for_response() {
  local expected_idx="$1"   # 4-digit zero-padded index string
  local start_time
  start_time=$(date +%s)
  local cb_count_before=0
  [ -f "$CALLBACKS_FILE" ] && cb_count_before=$(wc -l < "$CALLBACKS_FILE" | tr -d ' ')

  # Get current Telegram update_id baseline for direct polling fallback
  local TG_OFFSET
  TG_OFFSET=$(curl -sf "$TG_API/getUpdates?limit=1&timeout=0" 2>/dev/null | \
    jq -r '(.result[-1].update_id // 0) + 1' 2>/dev/null || echo "0")

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    [ "$elapsed" -ge "$TIMEOUT_SECS" ] && echo "" && return

    # ── Path 1: check callbacks file (written by OpenClaw main agent) ────
    if [ -f "$CALLBACKS_FILE" ]; then
      local current_count
      current_count=$(wc -l < "$CALLBACKS_FILE" | tr -d ' ')
      if [ "$current_count" -gt "$cb_count_before" ]; then
        # Read new lines
        local ACTION
        ACTION=$(tail -n $((current_count - cb_count_before)) "$CALLBACKS_FILE" | \
          jq -r --arg idx "$expected_idx" \
          'select(.idx == $idx) | .action' 2>/dev/null | head -1 || echo "")
        if [ -n "$ACTION" ]; then
          echo "$ACTION"
          return
        fi
        cb_count_before=$current_count
      fi
    fi

    # ── Path 2: direct getUpdates fallback ───────────────────────────────
    local UPDATES
    UPDATES=$(curl -sf "${TG_API}/getUpdates?offset=${TG_OFFSET}&timeout=5&limit=10" \
      2>/dev/null || echo "")
    if [ -n "$UPDATES" ]; then
      local LAST_ID
      LAST_ID=$(echo "$UPDATES" | jq -r '.result[-1].update_id // empty' 2>/dev/null || echo "")

      local ACTION
      ACTION=$(echo "$UPDATES" | jq -r --arg idx "$expected_idx" '
        .result[] |
        select(.callback_query.data | startswith("walk:")) |
        .callback_query.data |
        split(":") |
        if .[2] == $idx then .[1] else empty end
      ' 2>/dev/null | head -1 || echo "")

      if [ -n "$ACTION" ]; then
        # Acknowledge the update
        [ -n "$LAST_ID" ] && TG_OFFSET=$(( LAST_ID + 1 ))
        echo "$ACTION"
        return
      fi

      [ -n "$LAST_ID" ] && TG_OFFSET=$(( LAST_ID + 1 ))
    fi

    sleep 2
  done
}

# ── Main walkthrough loop ─────────────────────────────────────────────────
LABELED=0
SKIPPED=0
LAST_MSG_ID=""

# Announce session start
tg_send "🎓 Starting inbox training — $TOTAL senders to label.
Tap an action button for each sender. Take your time!"

# Load senders from session
SENDERS_JSON=$(python3 -c "import json; s=json.load(open('$SESSION_FILE')); print(json.dumps(s['senders']))")
SENDER_COUNT=$(echo "$SENDERS_JSON" | jq 'length')

i=0
while [ "$i" -lt "$SENDER_COUNT" ]; do
  SENDER_JSON=$(echo "$SENDERS_JSON" | jq ".[$i]")
  SENDER=$(echo "$SENDER_JSON" | jq -r '.sender')
  DOMAIN=$(echo "$SENDER_JSON" | jq -r '.domain')
  SUBJECT=$(echo "$SENDER_JSON" | jq -r '.sample_subject')
  COUNT=$(echo "$SENDER_JSON" | jq -r '.email_count')
  IDX_DISPLAY=$((i + 1))
  IDX_PAD=$(printf "%04d" "$IDX_DISPLAY")

  # Delete previous card to keep chat clean
  [ -n "$LAST_MSG_ID" ] && delete_msg "$LAST_MSG_ID"

  # Send the sender card
  LAST_MSG_ID=$(send_card "$SENDER" "$DOMAIN" "$SUBJECT" "$COUNT" "$IDX_DISPLAY" "$TOTAL")
  echo "[walkthrough] Card $IDX_DISPLAY/$TOTAL sent for $SENDER (msg_id=$LAST_MSG_ID)" >&2

  # Wait for response
  ACTION=$(wait_for_response "$IDX_PAD")

  if [ -z "$ACTION" ]; then
    echo "[walkthrough] No response for $SENDER after ${TIMEOUT_SECS}s — retrying card" >&2
    # Re-send the same card (don't advance i)
    continue
  fi

  echo "[walkthrough] $SENDER → $ACTION" >&2

  # ── Record the label ─────────────────────────────────────────────────
  LABELED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$ACTION" != "skip" ]; then
    # Update sender-preferences.json
    NEW_ENTRY=$(jq -cn \
      --arg sender   "$SENDER" \
      --arg domain   "$DOMAIN" \
      --arg action   "$ACTION" \
      --arg subject  "$SUBJECT" \
      --argjson count "$COUNT" \
      --arg ts       "$LABELED_AT" \
      '{sender:$sender, domain:$domain, action:$action, source:"active",
        confidence:1.0, topics:[], email_count:$count, last_updated:$ts,
        sample_subject:$subject}')

    PREFS=$([ -f "$PREFS_FILE" ] && cat "$PREFS_FILE" || echo "[]")
    echo "$PREFS" | jq \
      --arg sender "$SENDER" \
      --argjson entry "$NEW_ENTRY" \
      '[.[] | select(.sender != $sender)] + [$entry]' \
      > "${PREFS_FILE}.tmp" && mv "${PREFS_FILE}.tmp" "$PREFS_FILE"

    # For deep_read: fire topic extraction in background
    if [ "$ACTION" = "deep_read" ]; then
      bash "$SCRIPT_DIR/extract-sender-topics.sh" "$SENDER" > /dev/null 2>&1 &
      tg_send "📖 Extracting topics for $SENDER in the background…"
    fi

    LABELED=$((LABELED + 1))
    # Append label entry to session
    python3 - "$SESSION_FILE" "$SENDER" "$DOMAIN" "$ACTION" "$SUBJECT" "$COUNT" "$LABELED_AT" << 'PYEOF'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["labels"].append({
    "sender":         sys.argv[2],
    "domain":         sys.argv[3],
    "action":         sys.argv[4],
    "sample_subject": sys.argv[5],
    "email_count":    int(sys.argv[6]),
    "labeled_at":     sys.argv[7],
})
s["labeled"] = s.get("labeled", 0) + 1
p.write_text(json.dumps(s, indent=2))
PYEOF
  else
    SKIPPED=$((SKIPPED + 1))
    python3 - "$SESSION_FILE" << 'PYEOF'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["skipped"] = s.get("skipped", 0) + 1
p.write_text(json.dumps(s, indent=2))
PYEOF
  fi

  i=$((i + 1))
done

# Delete last card
[ -n "$LAST_MSG_ID" ] && delete_msg "$LAST_MSG_ID"

# ── Mark session complete ─────────────────────────────────────────────────
python3 - "$SESSION_FILE" << 'PYEOF'
import json, sys
from pathlib import Path
from datetime import datetime, timezone
p = Path(sys.argv[1])
s = json.loads(p.read_text())
s["completed_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
p.write_text(json.dumps(s, indent=2))
PYEOF

echo "[walkthrough] Session complete. Labeled=$LABELED  Skipped=$SKIPPED" >&2

# ── Generate rule diff + prompt for approval ─────────────────────────────
tg_send "✅ Done! Labeled $LABELED senders, skipped $SKIPPED.
Generating rule updates…"

bash "$SCRIPT_DIR/generate-rule-diff.sh"
DIFF_FILE="$DATA_DIR/rule-diff.txt"

if [ -f "$DIFF_FILE" ] && [ -s "$DIFF_FILE" ]; then
  DIFF_PREVIEW=$(head -40 "$DIFF_FILE")
  jq -cn \
    --arg chat_id "$CHAT_ID" \
    --arg text "$(printf "📋 Proposed triage-rules.md changes:\n\n%s\n\nApply all changes?" "$DIFF_PREVIEW")" \
    '{chat_id:$chat_id, text:$text, reply_markup:{
       inline_keyboard:[[
         {text:"✅ Apply all",   callback_data:"walkdiff:apply"},
         {text:"❌ Discard",     callback_data:"walkdiff:discard"}
       ]]
     }}' \
  | curl -sf -X POST "$TG_API/sendMessage" \
      -H "Content-Type: application/json" \
      -d @- > /dev/null 2>&1 || true
else
  tg_send "No rule changes generated."
fi
