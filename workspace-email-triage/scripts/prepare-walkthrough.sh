#!/bin/bash
set -euo pipefail
# prepare-walkthrough.sh — Deduplicate senders from email-history.jsonl,
# filter already-classified, rank by volume, cap at 40, write session JSON.

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
MEMORY_DIR="$WORKSPACE_TRIAGE/memory"

HISTORY_FILE="$DATA_DIR/email-history.jsonl"
PREFS_FILE="$DATA_DIR/sender-preferences.json"
TRIAGE_RULES="$MEMORY_DIR/triage-rules.md"
SESSION_FILE="$DATA_DIR/walkthrough-session.json"

if [ ! -f "$HISTORY_FILE" ] || [ ! -s "$HISTORY_FILE" ]; then
  echo "[prepare-walkthrough] ERROR: $HISTORY_FILE is empty or missing. Run extract-history.sh first." >&2
  exit 1
fi

echo "[prepare-walkthrough] Building sender queue..." >&2

python3 - "$HISTORY_FILE" "$PREFS_FILE" "$TRIAGE_RULES" "$SESSION_FILE" << 'PYEOF'
import json, re, sys
from pathlib import Path
from datetime import datetime, timezone
from collections import defaultdict

history_path, prefs_path, rules_path, session_path = \
    Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])

# ── 1. Collect already-classified senders ──────────────────────────────
classified = set()

if prefs_path.exists():
    try:
        for p in json.loads(prefs_path.read_text()):
            s = p.get("sender", "").lower().strip()
            if s:
                classified.add(s)
    except Exception:
        pass

if rules_path.exists():
    for m in re.finditer(r'"([^"\s]+@[^"\s]+)"', rules_path.read_text()):
        classified.add(m.group(1).lower().strip())

print(f"[prepare-walkthrough] Already classified: {len(classified)} senders", file=sys.stderr)

# ── 2. Parse email history ──────────────────────────────────────────────
def extract_email(from_field):
    m = re.search(r'<([^>@\s]+@[^>\s]+)>', from_field)
    if m:
        return m.group(1).lower()
    m = re.search(r'[\w.+\-]+@[\w.\-]+\.[a-zA-Z]{2,}', from_field)
    if m:
        return m.group(0).lower()
    return from_field.lower().strip()

by_sender = defaultdict(list)
with open(history_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
            addr = extract_email(e.get("from", ""))
            if addr:
                by_sender[addr].append(e)
        except Exception:
            continue

print(f"[prepare-walkthrough] Loaded {sum(len(v) for v in by_sender.values())} emails from {len(by_sender)} unique senders", file=sys.stderr)

# ── 3. Filter, deduplicate, rank ────────────────────────────────────────
senders = []
for addr, msgs in by_sender.items():
    if addr in classified:
        continue
    # Skip obvious system/no-reply if they have list-unsubscribe (bulk mail)
    # — user can still see them, just lower priority
    latest = max(msgs, key=lambda m: m.get("date", ""))
    domain = addr.split("@")[-1] if "@" in addr else ""
    senders.append({
        "sender":         addr,
        "domain":         domain,
        "email_count":    len(msgs),
        "sample_subject": latest.get("subject", ""),
        "sample_snippet": latest.get("snippet", "")[:120],
        "last_date":      latest.get("date", ""),
    })

# Sort by volume descending, cap at 40
senders.sort(key=lambda s: s["email_count"], reverse=True)
senders = senders[:40]
print(f"[prepare-walkthrough] Queue: {len(senders)} senders (after filter + cap)", file=sys.stderr)

# ── 4. Write walkthrough-session.json ──────────────────────────────────
today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
session = {
    "session_id":    f"{today}-001",
    "started_at":    datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "completed_at":  None,
    "total_senders": len(senders),
    "labeled":       0,
    "skipped":       0,
    "senders":       senders,
    "labels":        [],
}
session_path.write_text(json.dumps(session, indent=2))
print(f"[prepare-walkthrough] Wrote {session_path}  (total_senders={len(senders)})", file=sys.stderr)
PYEOF
