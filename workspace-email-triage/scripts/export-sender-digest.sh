#!/bin/bash
set -euo pipefail
# export-sender-digest.sh — Write extracted knowledge to state.db

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

KNOWLEDGE_ONLY="${1:-}"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
STATE_DB="$DATA_DIR/state.db"

INPUT_JSON=$(cat 2>/dev/null || echo "")

echo "[export-sender-digest] Running. Knowledge-only=$KNOWLEDGE_ONLY" >&2

if [ "$KNOWLEDGE_ONLY" = "--knowledge-only" ] && [ -n "$INPUT_JSON" ]; then
  # Write newsletter articles to state.db reading_list
  # Pass INPUT_JSON via env var to avoid stdin conflict with heredoc
  DIGEST_INPUT="$INPUT_JSON" STATE_DB_PATH="$STATE_DB" python3 -c '
import json, sqlite3, os, sys
from datetime import datetime, timezone

state_db = os.environ["STATE_DB_PATH"]
raw = os.environ.get("DIGEST_INPUT", "{}")

try:
    data = json.loads(raw)
except Exception as e:
    print(f"[export-sender-digest] Parse error: {e}", file=sys.stderr)
    sys.exit(0)

extraction = data.get("extraction", {})
articles = extraction.get("articles", [])

if not articles:
    print("[export-sender-digest] No articles to write", file=sys.stderr)
    sys.exit(0)

email = data.get("email", {})
newsletter_from = email.get("from", "Unknown")
received_date = datetime.now(timezone.utc).strftime("%b %-d, %Y")

conn = sqlite3.connect(state_db)
written = 0
for i, a in enumerate(articles):
    article_id = f"art_{email.get(\"msg_id\", \"unknown\")}_{i}"
    title = a.get("title", "")
    source = a.get("source", newsletter_from)
    newsletter = a.get("newsletter", newsletter_from)
    summary = a.get("summary", "")
    keypoints = json.dumps(a.get("keypoints", []))
    topics = json.dumps(a.get("topics", []))
    relevance = float(a.get("relevance", 0.5))
    if relevance < 0.5:
        continue
    conn.execute("""
        INSERT OR REPLACE INTO reading_list
        (id, title, source, newsletter, summary, takeaways, topics, relevance,
         received_date, user_opened, user_saved)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
    """, (article_id, title, source, newsletter, summary, keypoints, topics,
          relevance, received_date))
    written += 1

conn.commit()
conn.close()
print(f"[export-sender-digest] Wrote {written} article(s) to state.db", file=sys.stderr)
'
  echo "$INPUT_JSON"
else
  # Standard sender digest (write basic summary file)
  MEMORY_DIR="$WORKSPACE_TRIAGE/memory"
  DIGEST_FILE="$MEMORY_DIR/sender-preferences-digest.md"
  cat > "$DIGEST_FILE" << DIGEST
---
entity_type: sender_preferences_digest
generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
# Sender Preferences Digest

Auto-generated from sender-preferences.json.
DIGEST
  echo "[export-sender-digest] Digest written to $DIGEST_FILE" >&2
  echo "${INPUT_JSON:-{}}"
fi
