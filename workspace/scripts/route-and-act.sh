#!/usr/bin/env bash
# route-and-act.sh — Route an email to the correct action based on classification bucket.
# Reads classification+email JSON from stdin (output of classify-email.sh).
# For needs_reply: drafts reply (Haiku via email-triage agent), saves Gmail draft, sends Telegram approval.
# For review: sends Telegram notification, outputs JSON.
# For others: labels/trashes silently, outputs JSON.
set -euo pipefail

# Ensure node@22 is on PATH for openclaw calls (login shells used by Lobster may resolve older node).
export PATH="/usr/local/opt/node@22/bin:$PATH"

EMAIL_ID="$1"
TRIAGE_SCRIPTS_DIR="${TRIAGE_SCRIPTS_DIR:-$HOME/.openclaw/workspace/scripts}"
DRAFTS_FILE="${DRAFTS_FILE:-$HOME/.openclaw/workspace/data/pending-drafts.json}"

source "${HOME}/.openclaw/workspace/data/label-ids.env"

INPUT=$(cat)

BUCKET=$(echo "$INPUT" | jq -r '.bucket // "review"')
FROM=$(echo "$INPUT" | jq -r '.email.from // .from // "Unknown"')
SUBJECT=$(echo "$INPUT" | jq -r '.email.subject // .subject // "No subject"')
REASON=$(echo "$INPUT" | jq -r '.reason // ""')
THREAD_ID=$(echo "$INPUT" | jq -r '.email.thread_id // .thread_id // ""')
RFC_MESSAGE_ID=$(echo "$INPUT" | jq -r '.email.message_id // ""')

case "$BUCKET" in

  spam_junk)
    gws gmail users messages trash \
      --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')"
    echo "$INPUT" | jq '. + {action_taken: "trashed"}'
    ;;

  newsletter)
    gws gmail users messages modify \
      --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')" \
      --json "{\"addLabelIds\":[\"${LABEL_TRIAGE_NEWSLETTER}\"]}"
    echo "$INPUT" | jq '. + {action_taken: "labeled_newsletter"}'
    ;;

  notification)
    gws gmail users messages modify \
      --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')" \
      --json "{\"addLabelIds\":[\"${LABEL_TRIAGE_NOTIFICATION}\"]}"
    echo "$INPUT" | jq '. + {action_taken: "labeled_notification"}'
    ;;

  needs_reply)
    # Label
    gws gmail users messages modify \
      --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')" \
      --json "{\"addLabelIds\":[\"${LABEL_TRIAGE_NEEDSREPLY}\"]}"

    # Draft reply via Sonnet (separate script)
    DRAFT_OUTPUT=$(echo "$INPUT" | bash "$TRIAGE_SCRIPTS_DIR/draft-reply.sh")
    DRAFT_TEXT=$(echo "$DRAFT_OUTPUT" | jq -r '.draft_reply // "No draft generated"')

    # Build RFC 2822 message and save as a real Gmail draft
    RAW_MSG=$(printf "To: %s\r\nSubject: Re: %s\r\nIn-Reply-To: %s\r\nReferences: %s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s" \
      "$FROM" "$SUBJECT" "$RFC_MESSAGE_ID" "$RFC_MESSAGE_ID" "$DRAFT_TEXT")
    ENCODED_MSG=$(echo -n "$RAW_MSG" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    GMAIL_DRAFT_ID=$(gws gmail users drafts create \
      --params '{"userId":"me"}' \
      --json "$(jq -n --arg raw "$ENCODED_MSG" --arg tid "$THREAD_ID" \
        '{message:{raw:$raw,threadId:$tid}}')" \
      2>/dev/null | jq -r '.id // empty')

    # Store draft locally for retrieval after approval
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

    # Truncate for Telegram display (4096 char limit)
    MAX_DRAFT_DISPLAY=1500
    DISPLAY_DRAFT=$(echo "$DRAFT_TEXT" | head -c "$MAX_DRAFT_DISPLAY")
    if [ ${#DRAFT_TEXT} -gt $MAX_DRAFT_DISPLAY ]; then
      DISPLAY_DRAFT="${DISPLAY_DRAFT}... [truncated]"
    fi

    # Output approval preview — this feeds into the approve step.
    # The approve command's --preview-from-stdin reads this JSON.
    jq -n \
      --arg from "$FROM" \
      --arg subject "$SUBJECT" \
      --arg reason "$REASON" \
      --arg draft "$DISPLAY_DRAFT" \
      --arg email_id "$EMAIL_ID" \
    '{
      message: ("\u00f0\u009f\u0093\u00a7 Reply Needed\n\nFrom: " + $from + "\nSubject: " + $subject + "\nWhy: " + $reason + "\n\n\u00e2\u009c\u008f\u00ef\u00b8\u008f Draft:\n" + $draft),
      preview: ("Send this reply to " + $from + "?"),
      action_taken: "needs_approval",
      email_id: $email_id
    }'
    ;;

  review)
    gws gmail users messages modify \
      --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')" \
      --json "{\"addLabelIds\":[\"${LABEL_TRIAGE_REVIEW}\"]}"
    GMAIL_LINK="https://mail.google.com/mail/u/0/#inbox/${THREAD_ID}"

    # Send a Telegram notification (no approval gate — just a heads-up)
    openclaw message send \
      --channel telegram \
      --target "1771281565" \
      --message "$(printf '📬 Review Needed\n\nFrom: %s\nSubject: %s\nWhy: %s\n\nOpen in Gmail: %s' "$FROM" "$SUBJECT" "$REASON" "$GMAIL_LINK")"

    echo "$INPUT" | jq '. + {action_taken: "escalated_review"}'
    ;;

  *)
    # Unknown bucket — treat as review
    gws gmail users messages modify \
      --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')" \
      --json "{\"addLabelIds\":[\"${LABEL_TRIAGE_REVIEW}\"]}"
    echo "$INPUT" | jq '. + {action_taken: "unknown_bucket_fallback"}'
    ;;
esac
