#!/usr/bin/env python3
"""MenoMail Fly.io server — serves index.html + /api/digest (push-populated)."""

import json
import os
import logging
from pathlib import Path
from flask import Flask, jsonify, request, Response

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("menomail-server")

app = Flask(__name__)

PUSH_SECRET = os.environ.get("MENOMAIL_PUSH_SECRET", "")
_digest: dict = {}  # in-memory store; persists across auto-stops, resets on deploy

_EMPTY_DIGEST = {
    "home": {
        "date_display": "",
        "summary": "Waiting for first triage run…",
        "attention_count": 0,
        "attention": [],
        "handled": {"newsletters_archived": 0, "notifications_cleared": 0,
                    "replies_drafted": 0, "financial_filed": 0},
        "adaptations": [],
        "status": "ok",
    },
    "review": {"count": 0, "cards": []},
    "reading": {"count": 0, "topics": ["All"], "articles": []},
    "learn": {"senders": []},
}


@app.route("/")
def index():
    html_path = Path(__file__).parent / "index.html"
    return Response(html_path.read_bytes(), mimetype="text/html")


@app.route("/api/digest")
def get_digest():
    return jsonify(_digest if _digest else _EMPTY_DIGEST)


@app.route("/api/digest/update", methods=["POST"])
def update_digest():
    secret = request.headers.get("X-Push-Secret", "")
    if PUSH_SECRET and secret != PUSH_SECRET:
        return "unauthorized", 401
    data = request.get_json(force=True, silent=True)
    if not data:
        return "bad request", 400
    _digest.clear()
    _digest.update(data)
    log.info("Digest updated: %d review cards, %d articles",
             len(_digest.get("review", {}).get("cards", [])),
             len(_digest.get("reading", {}).get("articles", [])))
    return "ok", 200


@app.route("/health")
def health():
    return jsonify({"status": "ok", "has_data": bool(_digest)})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    log.info("MenoMail server starting on 0.0.0.0:%d", port)
    app.run(host="0.0.0.0", port=port, debug=False)
