#!/bin/bash
set -euo pipefail
# build-and-push-digest.sh — Build digest JSON from local data and push to Fly.io mini app

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE/data"
PENDING_DRAFTS="$DATA_DIR/pending-drafts.json"
STATE_DB="$DATA_DIR/state.db"
FLY_URL="${MENOMAIL_FLY_URL:-https://menomail.fly.dev}"
PUSH_SECRET="${MENOMAIL_PUSH_SECRET:-}"
TMP_PY="/tmp/menomail_build_digest_$$.py"

echo "[build-digest] Building digest from $PENDING_DRAFTS" >&2

# Write Python script to temp file (avoids quoting issues with heredoc)
cat > "$TMP_PY" << 'PYEOF'
import json, sqlite3, os, sys, html, re
from datetime import datetime, timezone
from pathlib import Path

pending_path = os.environ["PENDING_DRAFTS"]
state_db_path = os.environ["STATE_DB"]

try:
    drafts = json.loads(Path(pending_path).read_text())
except Exception:
    drafts = {}

def parse_age(created_at_str):
    try:
        dt = datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        secs = int(delta.total_seconds())
        if secs < 3600:
            return str(secs // 60) + "m ago"
        elif secs < 86400:
            return str(secs // 3600) + "h ago"
        else:
            return str(secs // 86400) + "d ago"
    except Exception:
        return "recently"

def parse_sender_name(from_field):
    decoded = html.unescape(from_field or "")
    m = re.match(r"^(.+?)\s*<", decoded)
    if m:
        name = m.group(1).strip().strip('"')
        return name if name else decoded.split("@")[0]
    m = re.search(r"([\w.+%-]+)@", decoded)
    return m.group(1) if m else (decoded[:20] or "Unknown")

def avatar_color(name):
    colors = ["#b91c1c","#b45309","#15803d","#0891b2","#6d28d9","#be185d","#7c3aed","#0369a1"]
    idx = sum(ord(c) for c in (name or "?")) % len(colors)
    return colors[idx]

cards = []
attention = []
for email_id, draft_info in drafts.items():
    from_raw = draft_info.get("from", "")
    sender_name = parse_sender_name(from_raw)
    initial = (sender_name[0].upper()) if sender_name else "?"
    subject = html.unescape(draft_info.get("subject", ""))
    age = parse_age(draft_info.get("created_at", ""))
    risk_flags = draft_info.get("risk_flags", [])
    has_risk = any(f.get("severity") == "red" for f in risk_flags)
    accent = "red" if has_risk else ("amber" if risk_flags else "dim")

    cards.append({
        "id": email_id,
        "card_type": "draft",
        "sender_name": sender_name,
        "sender_initial": initial,
        "avatar_color": avatar_color(sender_name),
        "subject": subject,
        "age": age,
        "original_text": "",
        "draft_text": draft_info.get("draft", ""),
        "gmail_draft_id": draft_info.get("gmail_draft_id", ""),
        "message_id": draft_info.get("message_id", ""),
        "tag": "needs_reply",
        "risk_flags": risk_flags,
        "context": None,
    })
    attention.append({
        "id": "attn_" + email_id,
        "sender": sender_name,
        "subject": subject,
        "age": age,
        "accent": accent,
        "action": "review",
    })

articles = []
topics_set = ["All"]
try:
    conn = sqlite3.connect(state_db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT * FROM reading_list WHERE user_opened=0 ORDER BY relevance DESC LIMIT 50"
    ).fetchall()
    conn.close()
    topics_seen = set()
    for a in rows:
        topics = json.loads(a["topics"] or "[]")
        kps = json.loads(a["takeaways"] or "[]")
        for t in topics:
            if t not in topics_seen:
                topics_set.append(t)
                topics_seen.add(t)
        articles.append({
            "id": a["id"],
            "source": a["source"],
            "source_label": a["newsletter"] or a["source"],
            "date": a["received_date"],
            "tag": topics[0] if topics else "",
            "topic": topics[0] if topics else "",
            "title": a["title"],
            "summary": a["summary"],
            "keypoints": kps,
            "relevance": a["relevance"],
        })
except Exception:
    pass

now = datetime.now(timezone.utc)
date_display = now.strftime("%A, %b %-d")
n = len(cards)
summary = str(n) + " email" + ("s" if n != 1 else "") + " need your attention." if n > 0 else "Everything handled."

digest = {
    "home": {
        "date_display": date_display,
        "summary": summary,
        "attention_count": n,
        "attention": attention,
        "handled": {
            "newsletters_archived": 0,
            "notifications_cleared": 0,
            "replies_drafted": n,
            "financial_filed": 0,
        },
        "adaptations": [],
        "status": "ok",
    },
    "review": {"count": n, "cards": cards},
    "reading": {
        "count": len(articles),
        "topics": topics_set,
        "articles": articles,
    },
    "learn": {"senders": []},
}
print(json.dumps(digest))
PYEOF

DIGEST=$(PENDING_DRAFTS="$PENDING_DRAFTS" STATE_DB="$STATE_DB" python3 "$TMP_PY" 2>&1)
EXIT_CODE=$?
rm -f "$TMP_PY"

if [ $EXIT_CODE -ne 0 ] || [ -z "$DIGEST" ]; then
  echo "[build-digest] ERROR: Failed to build digest: $DIGEST" >&2
  exit 1
fi

echo "[build-digest] Built digest ($(echo "$DIGEST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['review']['count'],'drafts,',d['reading']['count'],'articles')" 2>/dev/null || echo "ok"))" >&2

# ── Push to Fly.io ────────────────────────────────────────────────────────
echo "[build-digest] Pushing to $FLY_URL/api/digest/update" >&2

HTTP_STATUS=$(curl -sf -w "%{http_code}" -o /dev/null \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Push-Secret: $PUSH_SECRET" \
  --data-binary "$DIGEST" \
  "$FLY_URL/api/digest/update" 2>/dev/null || echo "000")

if [ "$HTTP_STATUS" = "200" ]; then
  echo "[build-digest] Digest pushed successfully" >&2
else
  echo "[build-digest] WARNING: Push returned HTTP $HTTP_STATUS" >&2
fi
