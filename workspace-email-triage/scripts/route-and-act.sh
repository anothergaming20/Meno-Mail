#!/bin/bash
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
LABEL_IDS_FILE="$DATA_DIR/label-ids.env"
PENDING_DRAFTS="$DATA_DIR/pending-drafts.json"

EMAIL_ID="${1:-}"

# Read classification JSON from stdin
INPUT_JSON=$(cat)

if [ -z "$EMAIL_ID" ]; then
  EMAIL_ID=$(printf '%s' "$INPUT_JSON" | jq -r '.email.msg_id // ""' 2>/dev/null || echo "")
fi

BUCKET=$(printf '%s' "$INPUT_JSON" | jq -r '.classification.bucket // "review"' 2>/dev/null || echo "review")
FROM=$(printf '%s' "$INPUT_JSON" | jq -r '.email.from // ""' 2>/dev/null || echo "")
SUBJECT=$(printf '%s' "$INPUT_JSON" | jq -r '.email.subject // ""' 2>/dev/null || echo "")

echo "[route-and-act] Email $EMAIL_ID → bucket: $BUCKET" >&2

# Load label IDs
if [ -f "$LABEL_IDS_FILE" ]; then
  source "$LABEL_IDS_FILE"
fi

MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"


# ── Apply label helper ────────────────────────────────────────────────────────
apply_label() {
  local MSG_ID="$1"
  local LABEL_ID="$2"
  local REMOVE_INBOX="${3:-false}"

  if [ -z "$LABEL_ID" ]; then
    echo "[route-and-act] WARNING: No label ID for bucket $BUCKET" >&2
    return 0
  fi

  local MODIFY_BODY
  if [ "$REMOVE_INBOX" = "true" ]; then
    MODIFY_BODY=$(jq -n --arg l "$LABEL_ID" '{"addLabelIds": [$l], "removeLabelIds": ["INBOX"]}')
  else
    MODIFY_BODY=$(jq -n --arg l "$LABEL_ID" '{"addLabelIds": [$l]}')
  fi

  curl -sf -X POST \
    -H "Authorization: Bearer $MATON_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$MODIFY_BODY" \
    "$MATON_BASE/messages/${MSG_ID}/modify" > /dev/null
}

# ── Route by bucket ──────────────────────────────────────────────────────────
case "$BUCKET" in

  spam_junk)
    # Trash it
    curl -sf -X POST \
      -H "Authorization: Bearer $MATON_API_KEY" \
      "$MATON_BASE/messages/${EMAIL_ID}/trash" > /dev/null
    echo "[route-and-act] Trashed $EMAIL_ID (spam_junk)" >&2
    ;;

  newsletter)
    apply_label "$EMAIL_ID" "${LABEL_TRIAGE_NEWSLETTER:-}" "true"
    echo "[route-and-act] Labeled newsletter + archived $EMAIL_ID" >&2
    ;;

  notification)
    apply_label "$EMAIL_ID" "${LABEL_TRIAGE_NOTIFICATION:-}" "true"
    echo "[route-and-act] Labeled notification + archived $EMAIL_ID" >&2
    ;;

  needs_reply)
    apply_label "$EMAIL_ID" "${LABEL_TRIAGE_NEEDSREPLY:-}" "false"

    # Draft reply via draft-reply agent
    DRAFT_RESULT=$("$SCRIPT_DIR/draft-reply.sh" <<< "$INPUT_JSON" 2>/dev/null || echo "")

    DRAFT_TEXT=$(printf '%s' "$DRAFT_RESULT" | jq -r '.draft_reply // ""' 2>/dev/null || echo "")

    if [ -z "$DRAFT_TEXT" ]; then
      echo "[route-and-act] WARNING: Draft generation failed for $EMAIL_ID" >&2
    else
      # Run risk analysis
      RISK_RESULT=$("$SCRIPT_DIR/analyse-draft.sh" <<< \
        "$(jq -n \
          --argjson email_data "$(printf '%s' "$INPUT_JSON" | jq '.email')" \
          --arg draft "$DRAFT_TEXT" \
          '{email: $email_data, draft: $draft}')" 2>/dev/null || echo '{"risk_flags":[]}')

      RISK_FLAGS=$(printf '%s' "$RISK_RESULT" | jq '.risk_flags // []' 2>/dev/null || echo "[]")
      RISK_COUNT=$(printf '%s' "$RISK_FLAGS" | jq 'length' 2>/dev/null || echo "0")

      # Save draft to Gmail via Maton API
      # Build RFC 2822 message
      TO_ADDR=$(printf '%s' "$INPUT_JSON" | jq -r '.email.from // ""')
      REPLY_SUBJECT="Re: $(printf '%s' "$INPUT_JSON" | jq -r '.email.subject // ""')"
      GMAIL_ADDR="${GMAIL_ADDRESS:-your@gmail.com}"
      MSG_ID_HEADER=$(printf '%s' "$INPUT_JSON" | jq -r '.email.message_id_header // ""')
      THREAD_ID=$(printf '%s' "$INPUT_JSON" | jq -r '.email.thread_id // ""')

      RFC2822="From: $GMAIL_ADDR
To: $TO_ADDR
Subject: $REPLY_SUBJECT
Content-Type: text/plain; charset=utf-8"

      # Add threading headers so reply appears in the correct thread
      if [ -n "$MSG_ID_HEADER" ]; then
        RFC2822="$RFC2822
In-Reply-To: $MSG_ID_HEADER
References: $MSG_ID_HEADER"
      fi

      RFC2822="$RFC2822

$DRAFT_TEXT"

      # Base64url encode (macOS compatible)
      ENCODED=$(printf '%s' "$RFC2822" | base64 | tr '+/' '-_' | tr -d '=\n')

      # Include threadId so Gmail places the draft in the right thread
      DRAFT_PAYLOAD=$(jq -n \
        --arg raw "$ENCODED" \
        --arg thread_id "$THREAD_ID" \
        '{"message": {"raw": $raw} + (if $thread_id != "" then {"threadId": $thread_id} else {} end)}')

      DRAFT_RESPONSE=$(printf '%s' "$DRAFT_PAYLOAD" | \
        curl -s -X POST \
          -H "Authorization: Bearer $MATON_API_KEY" \
          -H "Content-Type: application/json" \
          -d @- \
          "$MATON_BASE/drafts" || echo "")

      GMAIL_DRAFT_ID=$(printf '%s' "$DRAFT_RESPONSE" | jq -r '.id // ""' 2>/dev/null || echo "")

      # Save to pending-drafts.json (safe via jq)
      CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      DRAFT_ENTRY=$(jq -n \
        --arg draft "$DRAFT_TEXT" \
        --arg gmail_draft_id "$GMAIL_DRAFT_ID" \
        --arg from "$FROM" \
        --arg subject "$SUBJECT" \
        --arg message_id_header "$(printf '%s' "$INPUT_JSON" | jq -r '.email.message_id_header // ""')" \
        --arg created_at "$CREATED_AT" \
        --argjson risk_flags "$RISK_FLAGS" \
        '{draft: $draft, gmail_draft_id: $gmail_draft_id, from: $from, subject: $subject,
          message_id: $message_id_header, created_at: $created_at, risk_flags: $risk_flags}')

      # Atomically update pending-drafts.json
      CURRENT_DRAFTS=$(cat "$PENDING_DRAFTS" 2>/dev/null || echo "{}")
      printf '%s' "$CURRENT_DRAFTS" | jq \
        --arg key "$EMAIL_ID" \
        --argjson entry "$DRAFT_ENTRY" \
        '.[$key] = $entry' > "${PENDING_DRAFTS}.tmp" && \
        mv "${PENDING_DRAFTS}.tmp" "$PENDING_DRAFTS"

      echo "[route-and-act] Draft saved for $EMAIL_ID (risk_flags: $RISK_COUNT)" >&2
    fi
    ;;

  review)
    apply_label "$EMAIL_ID" "${LABEL_TRIAGE_REVIEW:-}" "false"
    echo "[route-and-act] Labeled for review: $EMAIL_ID" >&2
    ;;

  *)
    echo "[route-and-act] Unknown bucket: $BUCKET for $EMAIL_ID" >&2
    ;;
esac

# Pass through
echo "$INPUT_JSON"
