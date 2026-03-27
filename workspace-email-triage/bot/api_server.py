#!/usr/bin/env python3
"""MenoMail API Server — serves /api/digest from state.db for the Mini App."""

import json
import sqlite3
import logging
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, abort

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("menomail-api")

app = Flask(__name__)

WORKSPACE  = Path.home() / ".openclaw" / "workspace-email-triage"
STATE_DB   = WORKSPACE / "data" / "state.db"

def _open_db():
    if not STATE_DB.exists():
        abort(503, "state.db not initialized")
    conn = sqlite3.connect(str(STATE_DB))
    conn.row_factory = sqlite3.Row
    return conn

@app.route("/api/digest")
def get_digest():
    """Return pre-computed state for the Mini App."""
    conn = _open_db()

    try:
        # ── Review queue ──────────────────────────────────────────────────
        rows = conn.execute(
            "SELECT * FROM review_queue ORDER BY created_at DESC"
        ).fetchall()

        cards = []
        attention = []
        for row in rows:
            risk_flags = json.loads(row["risk_flags"] or "[]")
            card = {
                "id": row["id"],
                "card_type": "draft" if row["draft"] else "info",
                "sender_name": row["from_name"] or row["from_addr"],
                "sender_initial": (row["from_name"] or row["from_addr"] or "?")[0].upper(),
                "avatar_color": "#b91c1c",
                "subject": row["subject"],
                "age": row["age_display"],
                "original_text": row["snippet"],
                "draft_text": row["draft"],
                "gmail_draft_id": row["gmail_draft_id"],
                "message_id": row["message_id"],
                "tag": row["bucket"],
                "risk_flags": risk_flags,
                "context": None,
            }
            cards.append(card)

            accent = "red" if any(f.get("severity") == "red" for f in risk_flags) else "amber"
            attention.append({
                "id": "attn_" + row["id"],
                "sender": row["from_name"] or row["from_addr"],
                "subject": row["subject"],
                "age": row["age_display"],
                "accent": accent,
                "action": "review",
            })

        # ── Reading list ──────────────────────────────────────────────────
        articles_rows = conn.execute(
            "SELECT * FROM reading_list WHERE user_opened=0 ORDER BY relevance DESC"
        ).fetchall()

        articles = []
        topics_set = {"All"}
        for a in articles_rows:
            topics = json.loads(a["topics"] or "[]")
            kps    = json.loads(a["takeaways"] or "[]")
            for t in topics:
                topics_set.add(t)
            articles.append({
                "id": a["id"],
                "source": a["source"],
                "source_label": a["newsletter"] or a["source"],
                "date": a["received_date"],
                "tag": (topics[0] if topics else ""),
                "topic": (topics[0] if topics else ""),
                "title": a["title"],
                "summary": a["summary"],
                "keypoints": kps,
                "relevance": a["relevance"],
            })

        # ── Stats ─────────────────────────────────────────────────────────
        stats_row = conn.execute(
            "SELECT * FROM attention_stats ORDER BY date DESC LIMIT 1"
        ).fetchone()

        handled = {
            "newsletters_archived": 0,
            "notifications_cleared": 0,
            "replies_drafted": 0,
            "financial_filed": 0,
        }
        if stats_row:
            handled["replies_drafted"] = stats_row["needs_review"] or 0

        # ── Compose response ──────────────────────────────────────────────
        now = datetime.now(timezone.utc)
        date_display = now.strftime("%A, %b %-d")

        digest = {
            "home": {
                "date_display": date_display,
                "summary": f"{len(cards)} email(s) need attention.",
                "attention_count": len(attention),
                "attention": attention,
                "handled": handled,
                "adaptations": [],
                "status": "ok",
            },
            "review": {
                "count": len(cards),
                "cards": cards,
            },
            "reading": {
                "count": len(articles),
                "topics": sorted(topics_set),
                "articles": articles,
            },
            "learn": {
                "senders": [],
            },
        }

        return jsonify(digest)

    finally:
        conn.close()

@app.route("/health")
def health():
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    log.info(f"MenoMail API server starting on port 8888")
    app.run(host="127.0.0.1", port=8888, debug=False)
