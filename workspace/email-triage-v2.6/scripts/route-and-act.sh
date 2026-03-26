#!/usr/bin/env bash
# route-and-act.sh — Route email to correct action based on bucket. (v2.5)
# Reads classification+email JSON from stdin (output of classify-email.sh).
#
# v2.5 changes vs v2.4:
# - gws CLI replaced with Maton API Gateway (MATON_API_KEY bearer token)
# - Telegram chat ID read from env or secrets file, not hardcoded
# - Gmail API calls use curl + Maton base URL throughout

set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

EMAIL_ID="$1"
TRIAGE_SCRIPTS_DIR="${TRIAGE_SCRIPTS_DIR:-$HOME/.openclaw/workspace/scripts}"
DRAFTS_FILE="${DRAFTS_FILE:-$HOME/.openclaw/workspace/data/pending-drafts.json}"
MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$(cat "$HOME/.openclaw/secrets/telegram-chat-id" 2>/dev/null || echo '')}"

source "${HOME}/.openclaw/workspace/data/label-ids.env"

INPUT=$(cat)

BUCKET=$(echo "$INPUT" | jq -r '.bucket // "review"')
FROM=$(echo "$INPUT" | jq -r '.email.from // .from // "Unknown"')
SUBJECT=$(echo "$INPUT" | jq -r '.email.subject // .subject // "No subject"')
REASON=$(echo "$INPUT" | jq -r '.reason // ""')
THREAD_ID=$(echo "$INPUT" | jq -r '.email.thread_id // .thread_id // ""')
RFC_MESSAGE_ID=$(echo "$INPUT" | jq -r '.email.message_id // ""')

# ── Helper: add Gmail label via Maton ───────────────────────────────
add_label() {
  local label_id="$1"
  curl -sf -X POST \
    -H "Authorization: Bearer ${MATON_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"addLabelIds\":[\"${label_id}\"]}" \
    "${MATON_BASE}/messages/${EMAIL_ID}/modify" >/dev/null
}

# ── Helper: trash email via Maton ───────────────────────────────────
trash_email() {
  curl -sf -X POST \
    -H "Authorization: Bearer ${MATON_API_KEY}" \
    "${MATON_BASE}/messages/${EMAIL_ID}/trash" >/dev/null
}

case "$BUCKET" in

  spam_junk)
    trash_email
    echo "$INPUT" | jq '. + {action_taken: "trashed"}'
    ;;

  newsletter)
    add_label "$LABEL_TRIAGE_NEWSLETTER"
    echo "$INPUT" | jq '. + {action_taken: "labeled_newsletter"}'
    ;;

  notification)
    add_label "$LABEL_TRIAGE_NOTIFICATION"
    echo "$INPUT" | jq '. + {action_taken: "labeled_notification"}'
    ;;

  needs_reply)
    add_label "$LABEL_TRIAGE_NEEDSREPLY"

    # Draft reply (soul.md tone applies via agent context)
    DRAFT_OUTPUT=$(echo "$INPUT" | bash "$TRIAGE_SCRIPTS_DIR/draft-reply.sh")
    DRAFT_TEXT=$(echo "$DRAFT_OUTPUT" | jq -r '.draft_reply // "No draft generated"')

    # Build RFC 2822 message and save as Gmail draft via Maton
    RAW_MSG=$(printf "To: %s\r\nSubject: Re: %s\r\nIn-Reply-To: %s\r\nReferences: %s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s" \
      "$FROM" "$SUBJECT" "$RFC_MESSAGE_ID" "$RFC_MESSAGE_ID" "$DRAFT_TEXT")
    ENCODED_MSG=$(echo -n "$RAW_MSG" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')

    GMAIL_DRAFT_ID=$(curl -sf -X POST \
      -H "Authorization: Bearer ${MATON_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg raw "$ENCODED_MSG" --arg tid "$THREAD_ID" \
        '{message:{raw:$raw,threadId:$tid}}')" \
      "${MATON_BASE}/drafts" \
      2>/dev/null | jq -r '.id // empty')

    # Store draft locally for retrieval after Telegram approval
    mkdir -p "$(dirname "$DRAFTS_FILE")"
    [ -f "$DRAFTS_FILE" ] || echo '{}' > "$DRAFTS_FILE"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq --arg id "$EMAIL_ID" \
       --arg draft "$DRAFT_TEXT" \
       --arg from "$FROM" \
       --arg subject "$SUBJECT" \
       --arg ts "$TIMESTAMP" \
       --arg gmail_draft_id "$GMAIL_DRAFT_ID" \
       '.[$id] = {draft: $draft, from: $from, subject: $subject, created_at: $ts, gmail_draft_id: $gmail_draft_id}' \
       "$DRAFTS_FILE" > "${DRAFTS_FILE}.tmp" && mv "${DRAFTS_FILE}.tmp" "$DRAFTS_FILE"

    # Truncate for Telegram (4096 char limit)
    MAX_DRAFT_DISPLAY=1500
    DISPLAY_DRAFT=$(echo "$DRAFT_TEXT" | head -c "$MAX_DRAFT_DISPLAY")
    if [ ${#DRAFT_TEXT} -gt $MAX_DRAFT_DISPLAY ]; then
      DISPLAY_DRAFT="${DISPLAY_DRAFT}... [truncated]"
    fi

    # Send Telegram approval gate (inline buttons handled by OpenClaw channel)
    TELEGRAM_MSG=$(printf '📧 Reply Needed\n\nFrom: %s\nSubject: %s\nWhy: %s\n\n✏️ Draft:\n%s' \
      "$FROM" "$SUBJECT" "$REASON" "$DISPLAY_DRAFT")

    openclaw message send \
      --channel telegram \
      --target "$TELEGRAM_CHAT_ID" \
      --message "$TELEGRAM_MSG" \
      --button "Approve|send-approved-reply.sh ${EMAIL_ID}" \
      --button "Dismiss|echo dismissed" 2>/dev/null || true

    # Output JSON for Lobster pipeline (action_taken signals what happened)
    echo "$INPUT" | jq \
      --arg email_id "$EMAIL_ID" \
      --arg draft "$DRAFT_TEXT" \
      '. + {action_taken: "needs_approval", email_id: $email_id, draft_reply: $draft}'
    ;;

  review)
    add_label "$LABEL_TRIAGE_REVIEW"
    GMAIL_LINK="https://mail.google.com/mail/u/0/#inbox/${THREAD_ID}"

    openclaw message send \
      --channel telegram \
      --target "$TELEGRAM_CHAT_ID" \
      --message "$(printf '📬 Review Needed\n\nFrom: %s\nSubject: %s\nWhy: %s\n\nOpen in Gmail: %s' \
        "$FROM" "$SUBJECT" "$REASON" "$GMAIL_LINK")"

    echo "$INPUT" | jq '. + {action_taken: "escalated_review"}'
    ;;

  *)
    # Unknown bucket — safe fallback is review, never spam_junk
    add_label "$LABEL_TRIAGE_REVIEW"
    echo "$INPUT" | jq '. + {action_taken: "unknown_bucket_fallback"}'
    ;;
esac
