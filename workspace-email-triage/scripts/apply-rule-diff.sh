#!/bin/bash
set -euo pipefail
# apply-rule-diff.sh — Apply approved rule diff to triage-rules.md and
# sender-preferences.json. Called after user approves the diff preview.
# Also called from bot.py's apply_labels Mini App handler.

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
MEMORY_DIR="$WORKSPACE_TRIAGE/memory"

DIFF_JSON="$DATA_DIR/rule-diff.json"
PREFS_FILE="$DATA_DIR/sender-preferences.json"
TRIAGE_RULES="$MEMORY_DIR/triage-rules.md"

# ── Source: Mini App apply_labels payload (JSON array on stdin) OR diff file
INPUT_JSON=$(cat 2>/dev/null || echo "")

if [ -n "$INPUT_JSON" ] && echo "$INPUT_JSON" | jq -e 'type == "object"' > /dev/null 2>&1; then
  # Mini App format: {"sender@domain.com": "action", ...}
  echo "[apply-rule-diff] Applying Mini App label payload..." >&2
  ENTRIES=$(echo "$INPUT_JSON" | jq -c '
    to_entries | map({
      sender: .key,
      domain: (.key | split("@") | .[1] // ""),
      action: .value,
      sample_subject: "",
      email_count: 0
    })
  ')
elif [ -f "$DIFF_JSON" ]; then
  echo "[apply-rule-diff] Applying rule-diff.json..." >&2
  ENTRIES=$(jq -c '.entries' "$DIFF_JSON" 2>/dev/null || echo "[]")
else
  echo "[apply-rule-diff] ERROR: No diff JSON found and no stdin payload." >&2
  exit 1
fi

COUNT=$(echo "$ENTRIES" | jq 'length')
if [ "$COUNT" -eq 0 ]; then
  echo "[apply-rule-diff] Nothing to apply." >&2
  exit 0
fi

echo "[apply-rule-diff] Applying $COUNT entries..." >&2

# ── Map action → triage-rules.md section ─────────────────────────────────
action_to_section() {
  case "$1" in
    delete)    echo "## Spam/Junk (auto-trash immediately, no notification)" ;;
    archive)   echo "## Auto-Archive (archive without reading, no notification)" ;;
    scan)      echo "## Notifications (scan — Triage/Notification label, archived from inbox)" ;;
    deep_read) echo "## Newsletters (deep_read — Triage/Newsletter label, extract articles)" ;;
    important) echo "## VIP (needs_reply — always draft a reply)" ;;
    *)         echo "" ;;
  esac
}

# ── 1. Update triage-rules.md ────────────────────────────────────────────
python3 - "$TRIAGE_RULES" "$ENTRIES" << 'PYEOF'
import json, sys, re
from pathlib import Path

rules_path = Path(sys.argv[1])
entries    = json.loads(sys.argv[2])

SECTION_MAP = {
    "delete":    "## Spam/Junk (auto-trash immediately, no notification)",
    "archive":   "## Auto-Archive (archive without reading, no notification)",
    "scan":      "## Notifications (scan — Triage/Notification label, archived from inbox)",
    "deep_read": "## Newsletters (deep_read — Triage/Newsletter label, extract articles)",
    "important": "## VIP (needs_reply — always draft a reply)",
}

text  = rules_path.read_text() if rules_path.exists() else ""
lines = text.splitlines()

def already_in(sender, lines):
    return any(sender.lower() in l.lower() for l in lines)

# For each entry: find the right section and insert after the section header
# (before the next ## or ---).
by_section = {}
for e in entries:
    action = e.get("action", "")
    if action not in SECTION_MAP:
        continue
    section = SECTION_MAP[action]
    sender  = e.get("sender", "")
    note    = e.get("sample_subject", "")[:60]
    if not already_in(sender, lines):
        by_section.setdefault(section, []).append(f'- "{sender}" — {note}')

if not by_section:
    print("[apply-rule-diff] All senders already present in triage-rules.md", file=sys.stderr)
    sys.exit(0)

new_lines = []
current_section = None
for line in lines:
    new_lines.append(line)
    stripped = line.strip()
    if stripped.startswith("## "):
        current_section = stripped
        # Insert any new entries for this section right after its header
        if current_section in by_section:
            for entry_line in by_section.pop(current_section):
                new_lines.append(entry_line)

# If any sections weren't found (e.g. stripped section), append before ---END---
for section, entry_lines in by_section.items():
    new_lines.append("")
    new_lines.append(section)
    new_lines.extend(entry_lines)

rules_path.write_text("\n".join(new_lines) + "\n")
added = sum(len(v) for v in by_section.values()) if by_section else \
        sum(len(v) for v in {s: e for s, e in SECTION_MAP.items()}.values()) - sum(len(v) for v in by_section.values())
print(f"[apply-rule-diff] triage-rules.md updated", file=sys.stderr)
PYEOF

# ── 2. Update sender-preferences.json ────────────────────────────────────
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

while IFS= read -r ENTRY; do
  SENDER=$(echo "$ENTRY" | jq -r '.sender')
  DOMAIN=$(echo "$ENTRY" | jq -r '.domain // ""')
  ACTION=$(echo "$ENTRY" | jq -r '.action')
  SUBJECT=$(echo "$ENTRY" | jq -r '.sample_subject // ""')
  COUNT=$(echo "$ENTRY" | jq -r '.email_count // 0')

  [ -z "$SENDER" ] || [ -z "$ACTION" ] && continue

  NEW_ENTRY=$(jq -cn \
    --arg sender  "$SENDER" \
    --arg domain  "$DOMAIN" \
    --arg action  "$ACTION" \
    --arg subject "$SUBJECT" \
    --argjson count "$COUNT" \
    --arg ts      "$NOW" \
    '{sender:$sender, domain:$domain, action:$action, source:"active",
      confidence:1.0, topics:[], email_count:$count, last_updated:$ts,
      sample_subject:$subject}')

  PREFS=$([ -f "$PREFS_FILE" ] && cat "$PREFS_FILE" || echo "[]")
  echo "$PREFS" | jq \
    --arg sender "$SENDER" \
    --argjson entry "$NEW_ENTRY" \
    '[.[] | select(.sender != $sender)] + [$entry]' \
    > "${PREFS_FILE}.tmp" && mv "${PREFS_FILE}.tmp" "$PREFS_FILE"

done < <(echo "$ENTRIES" | jq -c '.[]')

echo "[apply-rule-diff] sender-preferences.json updated." >&2

# ── 3. Export sender digest ───────────────────────────────────────────────
bash "$SCRIPT_DIR/export-sender-digest.sh" < /dev/null > /dev/null 2>&1 || true

echo "[apply-rule-diff] Done." >&2
