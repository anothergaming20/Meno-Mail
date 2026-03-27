#!/usr/bin/env python3
"""MenoMail Telegram Bot — handles slash commands and Mini App callbacks."""

import json
import os
import subprocess
import sqlite3
import logging
from pathlib import Path

import telebot
from telebot.types import BotCommand, InlineKeyboardMarkup, InlineKeyboardButton, WebAppInfo

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("menomail-bot")

# ── Config ───────────────────────────────────────────────────────────────────
LEARN_APP_URL = "https://menomail-learn.fly.dev"
MAIN_APP_URL  = "https://menomail.fly.dev"

SCRIPTS_DIR   = Path.home() / ".openclaw" / "workspace-email-triage" / "scripts"
WORKSPACE     = Path.home() / ".openclaw" / "workspace-email-triage"
STATE_DB      = WORKSPACE / "data" / "state.db"
PENDING_DRAFTS = WORKSPACE / "data" / "pending-drafts.json"
LABEL_IDS_ENV  = WORKSPACE / "data" / "label-ids.env"
TOPICS_FILE   = WORKSPACE / "data" / "topics-interests.json"

# Load bot token from secrets file (preferred) or env
def _load_secret(path: str, env_var: str) -> str:
    p = Path(path)
    if p.exists():
        return p.read_text().strip()
    return os.environ.get(env_var, "")

BOT_TOKEN = _load_secret(
    os.path.expanduser("~/.openclaw/secrets/telegram-bot-token"),
    "TELEGRAM_BOT_TOKEN",
)
CHAT_ID = _load_secret(
    os.path.expanduser("~/.openclaw/secrets/telegram-chat-id"),
    "TELEGRAM_CHAT_ID",
)

if not BOT_TOKEN:
    raise RuntimeError("No Telegram bot token found. Set TELEGRAM_BOT_TOKEN or create ~/.openclaw/secrets/telegram-bot-token")

bot = telebot.TeleBot(BOT_TOKEN)

# ── Topics helpers ────────────────────────────────────────────────────────
def _load_topics() -> list:
    if TOPICS_FILE.exists():
        try:
            return json.loads(TOPICS_FILE.read_text()).get("topics", [])
        except Exception:
            return []
    return []

def _save_topics(topics: list):
    TOPICS_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOPICS_FILE.write_text(json.dumps({"topics": topics}, indent=2))

# ── Register bot commands (run on startup) ────────────────────────────────
bot.set_my_commands([
    BotCommand("/start",        "Open Meno Mail"),
    BotCommand("/learn",        "Start inbox training session"),
    BotCommand("/review",       "Open review queue"),
    BotCommand("/reading",      "Open reading list"),
    BotCommand("/status",       "Check agent status"),
    BotCommand("/topics",       "List your topics of interest"),
    BotCommand("/addtopic",     "Add a topic — /addtopic AI ethics"),
    BotCommand("/removetopic",  "Remove a topic — /removetopic 2"),
])
log.info("Bot commands registered")

# ── /start — open main Mini App ───────────────────────────────────────────
@bot.message_handler(commands=["start"])
def cmd_start(message):
    kb = InlineKeyboardMarkup()
    kb.add(InlineKeyboardButton("📬 Open Meno Mail →", web_app=WebAppInfo(url=MAIN_APP_URL)))
    bot.send_message(message.chat.id, "Meno Mail is running.", reply_markup=kb)

# ── /learn — open Learn Mini App ─────────────────────────────────────────
@bot.message_handler(commands=["learn"])
def cmd_learn(message):
    session_ready = subprocess.run(
        ["bash", str(SCRIPTS_DIR / "check-learn-session.sh")],
        capture_output=True,
    ).returncode == 0

    if session_ready:
        caption = "🎓 *Inbox Training ready*\nNew senders to classify\\. Tap below to start\\."
    else:
        caption = "🎓 *Inbox Training*\nNo new senders right now — you can still review existing rules\\."

    kb = InlineKeyboardMarkup()
    kb.add(InlineKeyboardButton("Start labeling →", web_app=WebAppInfo(url=LEARN_APP_URL)))
    bot.send_message(message.chat.id, caption, parse_mode="MarkdownV2", reply_markup=kb)

# ── /review ───────────────────────────────────────────────────────────────
@bot.message_handler(commands=["review"])
def cmd_review(message):
    kb = InlineKeyboardMarkup()
    kb.add(InlineKeyboardButton("Open Review →", web_app=WebAppInfo(url=MAIN_APP_URL + "?screen=review")))
    bot.send_message(message.chat.id, "Opening your review queue.", reply_markup=kb)

# ── /reading ──────────────────────────────────────────────────────────────
@bot.message_handler(commands=["reading"])
def cmd_reading(message):
    kb = InlineKeyboardMarkup()
    kb.add(InlineKeyboardButton("Open Reading →", web_app=WebAppInfo(url=MAIN_APP_URL + "?screen=reading")))
    bot.send_message(message.chat.id, "Opening your reading list.", reply_markup=kb)

# ── /status ───────────────────────────────────────────────────────────────
@bot.message_handler(commands=["status"])
def cmd_status(message):
    result = subprocess.run(
        ["bash", str(SCRIPTS_DIR / "agent-status.sh")],
        capture_output=True, text=True,
    )
    bot.send_message(message.chat.id, result.stdout or "Agent running.")

# ── /topics ───────────────────────────────────────────────────────────────
@bot.message_handler(commands=["topics"])
def cmd_topics(message):
    topics = _load_topics()
    if not topics:
        text = "No topics set yet.\nUse /addtopic &lt;topic&gt; to add one.\nExample: /addtopic AI and machine learning"
    else:
        lines = "\n".join(f"{i+1}. {t}" for i, t in enumerate(topics))
        text = f"<b>Your topics of interest:</b>\n\n{lines}\n\nUse /addtopic &lt;topic&gt; or /removetopic &lt;number&gt; to manage."
    bot.send_message(message.chat.id, text, parse_mode="HTML")

# ── /addtopic ─────────────────────────────────────────────────────────────
@bot.message_handler(commands=["addtopic"])
def cmd_addtopic(message):
    topic = message.text.replace("/addtopic", "", 1).strip()
    if not topic:
        bot.send_message(message.chat.id, "Usage: /addtopic &lt;topic&gt;\nExample: /addtopic AI and machine learning", parse_mode="HTML")
        return
    topics = _load_topics()
    if topic in topics:
        bot.send_message(message.chat.id, f"Already in your list: {topic}")
        return
    topics.append(topic)
    _save_topics(topics)
    bot.send_message(message.chat.id, f"Added: {topic}\n\nUse /topics to see all.")

# ── /removetopic ──────────────────────────────────────────────────────────
@bot.message_handler(commands=["removetopic"])
def cmd_removetopic(message):
    arg = message.text.replace("/removetopic", "", 1).strip()
    topics = _load_topics()
    if not topics:
        bot.send_message(message.chat.id, "No topics to remove.")
        return
    try:
        idx = int(arg) - 1
        if idx < 0 or idx >= len(topics):
            raise ValueError()
        removed = topics.pop(idx)
        _save_topics(topics)
        bot.send_message(message.chat.id, f"Removed: {removed}")
    except ValueError:
        lines = "\n".join(f"{i+1}. {t}" for i, t in enumerate(topics))
        bot.send_message(message.chat.id, f"Usage: /removetopic &lt;number&gt;\n\nCurrent topics:\n{lines}", parse_mode="HTML")

# ── Inline button callbacks ───────────────────────────────────────────────
@bot.callback_query_handler(func=lambda call: True)
def handle_callback(call):
    data = call.data or ""
    log.info(f"Callback: {data}")

    if data.startswith("send_draft:"):
        email_id = data.split(":", 1)[1]
        _send_draft(email_id, call.message.chat.id)

    elif data.startswith("dismiss_draft:"):
        email_id = data.split(":", 1)[1]
        _dismiss_draft(email_id, call.message.chat.id)

    elif data.startswith("snooze:"):
        parts = data.split(":")
        bot.send_message(call.message.chat.id, "Snoozed (Phase 2 feature).")

    elif data.startswith("dismiss:"):
        bot.answer_callback_query(call.id, "Dismissed")

    bot.answer_callback_query(call.id)

def _send_draft(email_id: str, chat_id: int):
    """Send approved draft via send-approved-reply.sh."""
    result = subprocess.run(
        ["bash", str(SCRIPTS_DIR / "send-approved-reply.sh"), email_id],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        bot.send_message(chat_id, "Reply sent.")
        log.info(f"Draft sent for {email_id}")
    else:
        bot.send_message(chat_id, f"Failed to send reply: {result.stderr[:200]}")
        log.error(f"send_approved_reply failed for {email_id}: {result.stderr}")

def _dismiss_draft(email_id: str, chat_id: int):
    """Remove draft from pending-drafts.json without sending."""
    try:
        drafts_path = PENDING_DRAFTS
        if drafts_path.exists():
            drafts = json.loads(drafts_path.read_text())
            if email_id in drafts:
                del drafts[email_id]
                drafts_path.write_text(json.dumps(drafts, indent=2))
        bot.send_message(chat_id, "Draft dismissed.")
        log.info(f"Draft dismissed for {email_id}")
    except Exception as e:
        bot.send_message(chat_id, "Error dismissing draft.")
        log.error(f"dismiss_draft error: {e}")

# ── Mini App sendData() callbacks ─────────────────────────────────────────
@bot.message_handler(content_types=["web_app_data"])
def handle_miniapp_action(message):
    raw = message.web_app_data.data
    log.info(f"Mini App data: {raw[:200]}")
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        log.error(f"Failed to parse Mini App data: {raw}")
        return

    action  = event.get("action")
    payload = event.get("data")

    if action == "send_draft":
        _send_draft(str(payload), message.chat.id)

    elif action == "apply_labels":
        _write_sender_prefs(payload)
        subprocess.run(["bash", str(SCRIPTS_DIR / "apply-rule-diff.sh")])
        bot.send_message(message.chat.id, "Labels applied.")

    elif action == "read_more_like":
        _update_topic_interests(payload.get("topic", ""), "up")

    elif action == "read_less_like":
        _update_topic_interests(payload.get("topic", ""), "down")

    elif action == "save_article":
        _mark_article_saved(str(payload))

    elif action == "dismiss_article":
        _remove_from_reading(str(payload))

    elif action == "archive":
        bot.send_message(message.chat.id, "📁 Archived.")

    else:
        log.warning(f"Unknown Mini App action: {action}")

def _write_sender_prefs(payload):
    """Write sender preferences from apply_labels action."""
    try:
        prefs_path = WORKSPACE / "data" / "sender-preferences.json"
        prefs = json.loads(prefs_path.read_text()) if prefs_path.exists() else []
        if isinstance(payload, dict):
            for sender, action in payload.items():
                entry = {"sender": sender, "action": action, "source": "active", "confidence": 1.0}
                prefs = [p for p in prefs if p.get("sender") != sender]
                prefs.append(entry)
            prefs_path.write_text(json.dumps(prefs, indent=2))
    except Exception as e:
        log.error(f"write_sender_prefs error: {e}")

def _update_topic_interests(topic: str, direction: str):
    """Update topic interest weights (Phase 2 feature stub)."""
    log.info(f"Topic interest update: {topic} → {direction} (Phase 2)")

def _mark_article_saved(article_id: str):
    """Mark article as saved in state.db."""
    try:
        conn = sqlite3.connect(str(STATE_DB))
        conn.execute("UPDATE reading_list SET user_saved=1 WHERE id=?", (article_id,))
        conn.commit()
        conn.close()
    except Exception as e:
        log.error(f"mark_article_saved error: {e}")

def _remove_from_reading(article_id: str):
    """Remove article from reading list in state.db."""
    try:
        conn = sqlite3.connect(str(STATE_DB))
        conn.execute("DELETE FROM reading_list WHERE id=?", (article_id,))
        conn.commit()
        conn.close()
    except Exception as e:
        log.error(f"remove_from_reading error: {e}")

# ── Start local webhook server ────────────────────────────────────────────────
# Phase 1: OpenClaw is already polling the same bot token (its Telegram channel).
# bot.py runs as a local webhook receiver on port 8080. OpenClaw forwards specific
# events here in Phase 3. In Phase 1, the email-triage agent handles inline button
# callbacks directly via its session, and send-approved-reply.sh is called from
# OpenClaw's cron/agent context.
if __name__ == "__main__":
    log.info(f"MenoMail bot webhook server starting on 127.0.0.1:8080 (chat_id={CHAT_ID})")

    from flask import Flask as _Flask, request as _req
    _app = _Flask("bot-webhook")

    @_app.route("/webhook", methods=["POST"])
    def _webhook():
        """Receive Telegram updates forwarded from OpenClaw or direct webhook."""
        update = _req.get_json(force=True)
        bot.process_new_updates([telebot.types.Update.de_json(update)])
        return "ok"

    @_app.route("/health")
    def _bot_health():
        return "bot ok"

    @_app.route("/send-draft/<email_id>", methods=["POST"])
    def _api_send_draft(email_id):
        """REST endpoint called by approve flow from scripts."""
        _send_draft(email_id, int(CHAT_ID))
        return "ok"

    log.info("Bot webhook server listening on 127.0.0.1:8080")
    _app.run(host="127.0.0.1", port=8080, debug=False)
