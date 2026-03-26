#!/bin/bash
set -euo pipefail
# generate-rule-diff.sh — Convert completed walkthrough-session.json labels
# into proposed additions for triage-rules.md.
# Output: data/rule-diff.txt (human-readable preview)
#         data/rule-diff.json (machine-readable, consumed by apply-rule-diff.sh)

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"

SESSION_FILE="$DATA_DIR/walkthrough-session.json"
DIFF_TXT="$DATA_DIR/rule-diff.txt"
DIFF_JSON="$DATA_DIR/rule-diff.json"

if [ ! -f "$SESSION_FILE" ]; then
  echo "[generate-rule-diff] ERROR: $SESSION_FILE not found." >&2
  exit 1
fi

python3 - "$SESSION_FILE" "$DIFF_TXT" "$DIFF_JSON" << 'PYEOF'
import json, sys
from pathlib import Path
from datetime import datetime, timezone

session_path = Path(sys.argv[1])
diff_txt_path = Path(sys.argv[2])
diff_json_path = Path(sys.argv[3])

session = json.loads(session_path.read_text())
labels = session.get("labels", [])

# Map action → triage-rules.md section header
SECTION_MAP = {
    "delete":     "## Spam/Junk (auto-trash immediately, no notification)",
    "archive":    "## Auto-Archive (archive without reading, no notification)",
    "scan":       "## Notifications (scan — Triage/Notification label, archived from inbox)",
    "deep_read":  "## Newsletters (deep_read — Triage/Newsletter label, extract articles)",
    "important":  "## VIP (needs_reply — always draft a reply)",
}
ACTION_DESC = {
    "delete":    "Spam/Junk  (auto-trash)",
    "archive":   "Auto-Archive",
    "scan":      "Notification (scan)",
    "deep_read": "Newsletter (deep_read)",
    "important": "VIP (needs_reply)",
}

by_action = {}
for label in labels:
    action = label.get("action")
    if action not in SECTION_MAP:
        continue
    by_action.setdefault(action, []).append(label)

# ── Human-readable diff ───────────────────────────────────────────────────
lines = [
    f"# MenoMail triage-rules.md — proposed changes",
    f"# Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    f"# Session: {session.get('session_id','')}",
    f"# Labeled: {session.get('labeled',0)}  Skipped: {session.get('skipped',0)}",
    "",
]
for action, entries in sorted(by_action.items()):
    section = SECTION_MAP[action]
    desc = ACTION_DESC[action]
    lines.append(f"### {desc}")
    for e in entries:
        note = e.get("sample_subject", "")[:60]
        lines.append(f'- "{e["sender"]}" — {note}')
    lines.append("")

diff_txt_path.write_text("\n".join(lines))

# ── Machine-readable diff ─────────────────────────────────────────────────
diff = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "session_id": session.get("session_id", ""),
    "entries": [
        {
            "sender":         e["sender"],
            "domain":         e.get("domain", ""),
            "action":         e["action"],
            "section":        SECTION_MAP[e["action"]],
            "sample_subject": e.get("sample_subject", ""),
            "email_count":    e.get("email_count", 0),
        }
        for e in labels if e.get("action") in SECTION_MAP
    ],
}
diff_json_path.write_text(json.dumps(diff, indent=2))

print(f"[generate-rule-diff] {len(diff['entries'])} entries → {diff_txt_path.name} + {diff_json_path.name}", file=sys.stderr)
PYEOF
