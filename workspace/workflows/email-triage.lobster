# email-triage.lobster
# Per-email triage workflow. Invoked by dispatcher.sh via:
#   lobster run --file email-triage.lobster --args-json '{"email_id":"<id>"}'
#
# Pipeline: fetch → classify → mark_processed → route_and_act
# LLM calls use `openclaw agent --agent email-triage` (Haiku) inside classify-email.sh and draft-reply.sh.
# Telegram approval for needs_reply is handled out-of-band:
#   route-and-act.sh sends a preview to Telegram; user taps Approve → send-approved-reply.sh.

name: email-triage
description: "Classify one email and take the appropriate action"

args:
  email_id:
    default: ""

env:
  TRIAGE_SCRIPTS_DIR: "/Users/aiagnet/.openclaw/workspace/scripts"
  TRIAGE_RULES_PATH: "/Users/aiagnet/.openclaw/workspace/memory/triage-rules.md"
  DRAFTS_FILE: "/Users/aiagnet/.openclaw/workspace/data/pending-drafts.json"

steps:
  # ── Step 1: Fetch email from Gmail → structured JSON ─────────────────
  # Extracts: email_id, thread_id, message_id (RFC 2822), from, to,
  # subject, date, body_text (truncated to 3000 chars).
  - id: fetch_message
    command: |-
      SCRIPTS="$HOME/.openclaw/workspace/scripts"
      bash "$SCRIPTS/fetch-email.sh" "${email_id}"

  # ── Step 2: Classify into one of 5 buckets ───────────────────────────
  # Uses `openclaw agent --agent email-triage` (Haiku, fast + cheap).
  # Buckets: spam_junk | newsletter | notification | needs_reply | review
  # Output: {bucket, confidence, reason, email: {...}}
  - id: classify
    stdin: $fetch_message.stdout
    command: |-
      SCRIPTS="$HOME/.openclaw/workspace/scripts"
      bash "$SCRIPTS/classify-email.sh"

  # ── Step 3: Apply Triage/Processed label (always, non-blocking) ──────
  # Prevents reprocessing on the next cron run regardless of routing outcome.
  # Passes classify output through to stdout for the next step.
  - id: mark_processed
    stdin: $classify.stdout
    command: |-
      SCRIPTS="$HOME/.openclaw/workspace/scripts"
      bash "$SCRIPTS/mark-processed.sh" "${email_id}"

  # ── Step 4: Route based on bucket ────────────────────────────────────
  # spam_junk     → trash via gws
  # newsletter    → apply Triage/Newsletter label
  # notification  → apply Triage/Notification label
  # needs_reply   → apply label + draft reply (llm-task) + save Gmail draft
  #                 + send Telegram preview with approve/dismiss
  # review        → apply label + send Telegram heads-up
  # Approval for needs_reply is out-of-band: user taps Approve in Telegram
  # which triggers send-approved-reply.sh separately.
  - id: route_and_act
    stdin: $mark_processed.stdout
    command: |-
      SCRIPTS="$HOME/.openclaw/workspace/scripts"
      bash "$SCRIPTS/route-and-act.sh" "${email_id}"
