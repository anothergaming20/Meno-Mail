#!/bin/bash
set -euo pipefail
# extract-sender-topics.sh — Haiku LLM topic extraction for a deep_read sender.
# Usage: extract-sender-topics.sh <sender-email>
# Output: JSON array of topic strings on stdout.
# Side-effects: appends to topic-interests.md and updates sender-preferences.json.

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

SENDER="${1:-}"
if [ -z "$SENDER" ]; then
  echo "[extract-sender-topics] ERROR: sender address required as first argument" >&2
  exit 1
fi

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
MEMORY_DIR="$WORKSPACE_TRIAGE/memory"

HISTORY_FILE="$DATA_DIR/email-history.jsonl"
PREFS_FILE="$DATA_DIR/sender-preferences.json"
TOPIC_FILE="$MEMORY_DIR/topic-interests.md"

# ── Ensure topic-interests.md exists ─────────────────────────────────────
if [ ! -f "$TOPIC_FILE" ]; then
  cat > "$TOPIC_FILE" << 'EOF'
## Confirmed (user-selected)

## Inferred (high engagement, not yet confirmed)

## Not interested (user explicitly deselected)
EOF
fi

# ── Fetch last 10 subjects + snippets for this sender ────────────────────
SENDER_LOWER=$(echo "$SENDER" | tr '[:upper:]' '[:lower:]')

SAMPLES=$(python3 - "$HISTORY_FILE" "$SENDER_LOWER" << 'PYEOF'
import json, re, sys
from pathlib import Path

hist_path = Path(sys.argv[1])
sender    = sys.argv[2]

def extract_email(from_field):
    m = re.search(r'<([^>@\s]+@[^>\s]+)>', from_field)
    if m: return m.group(1).lower()
    m = re.search(r'[\w.+\-]+@[\w.\-]+', from_field)
    if m: return m.group(0).lower()
    return from_field.lower().strip()

matches = []
if hist_path.exists():
    with open(hist_path) as f:
        for line in f:
            try:
                e = json.loads(line.strip())
                if extract_email(e.get("from", "")) == sender:
                    matches.append(e)
            except Exception:
                pass

matches.sort(key=lambda x: x.get("date", ""), reverse=True)
out = [{"subject": m.get("subject",""), "snippet": m.get("snippet","")[:100]}
       for m in matches[:10]]
print(json.dumps(out))
PYEOF
)

if [ "$SAMPLES" = "[]" ] || [ -z "$SAMPLES" ]; then
  echo "[extract-sender-topics] No history found for $SENDER" >&2
  echo "[]"
  exit 0
fi

SAMPLE_COUNT=$(echo "$SAMPLES" | jq 'length')
echo "[extract-sender-topics] Extracting topics from $SAMPLE_COUNT emails for $SENDER..." >&2

# ── Build LLM prompt (safe via jq) ───────────────────────────────────────
PROMPT=$(jq -rn \
  --arg sender "$SENDER" \
  --argjson samples "$SAMPLES" \
  '"You are extracting topic tags from email subjects and snippets.\n\nSender: \($sender)\n\nEmails:\n" +
   ($samples | map("Subject: \(.subject)\nSnippet: \(.snippet)") | join("\n---\n")) +
   "\n\nReturn ONLY a JSON array of 2–5 short topic strings (2–4 words each). No markdown, no preamble.\nExample: [\"product updates\",\"developer tools\",\"API changes\"]"')

# ── Call Haiku via email-triage agent ─────────────────────────────────────
AGENT_RESP=$(openclaw agent \
  --agent email-triage \
  --session-id "topics-$$" \
  --message "$PROMPT" \
  --json 2>/dev/null || echo "")

RAW_TEXT=$(echo "$AGENT_RESP" | jq -r '
  .result.payloads[0].text //
  .result.payloads[].text //
  .text // ""
' 2>/dev/null || echo "")

# Extract the JSON array from the response
TOPICS=$(echo "$RAW_TEXT" | python3 -c "
import sys, json, re
t = sys.stdin.read()
m = re.search(r'\[[\s\S]*?\]', t)
if m:
    try:
        arr = json.loads(m.group())
        print(json.dumps([str(x).strip() for x in arr if x]))
        sys.exit(0)
    except Exception:
        pass
print('[]')
" 2>/dev/null || echo "[]")

if [ "$TOPICS" = "[]" ]; then
  echo "[extract-sender-topics] LLM returned no topics for $SENDER" >&2
  echo "[]"
  exit 0
fi

echo "[extract-sender-topics] Topics: $TOPICS" >&2

# ── Append new topics to ## Confirmed section of topic-interests.md ───────
python3 - "$TOPIC_FILE" "$TOPICS" << 'PYEOF'
import sys, json
from pathlib import Path

topic_file = Path(sys.argv[1])
topics     = json.loads(sys.argv[2])
text       = topic_file.read_text()
lines      = text.splitlines()

existing = set(l.strip().lstrip("- ").lower() for l in lines if l.strip().startswith("- "))

new_lines = []
in_confirmed = False
inserted = False
for line in lines:
    new_lines.append(line)
    if line.strip() == "## Confirmed (user-selected)":
        in_confirmed = True
        if not inserted:
            for topic in topics:
                if topic.lower() not in existing:
                    new_lines.append(f"- {topic}")
            inserted = True
    elif line.startswith("## ") and in_confirmed:
        in_confirmed = False

topic_file.write_text("\n".join(new_lines) + "\n")
PYEOF

# ── Update sender-preferences.json with topics ───────────────────────────
if [ -f "$PREFS_FILE" ]; then
  UPDATED=$(jq \
    --arg sender "$SENDER" \
    --argjson topics "$TOPICS" \
    'map(if (.sender | ascii_downcase) == ($sender | ascii_downcase)
         then . + {topics: $topics}
         else . end)' \
    "$PREFS_FILE" 2>/dev/null || cat "$PREFS_FILE")
  echo "$UPDATED" > "${PREFS_FILE}.tmp" && mv "${PREFS_FILE}.tmp" "$PREFS_FILE"
fi

echo "$TOPICS"
