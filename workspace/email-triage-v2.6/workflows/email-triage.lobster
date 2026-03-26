# email-triage.lobster (v2.6)
# Per-email triage workflow. Called by run-triage.sh via:
#   lobster run --file email-triage.lobster --args-json '{"email_id":"<id>"}'
#
# run-triage.sh is itself called by the email-triage agent's exec tool during
# its isolated cron agentTurn session. This means every Lobster step runs
# inside an OpenClaw agent session context, so:
#   - openclaw.invoke is available in step commands
#   - classify-email.sh and draft-reply.sh use llm-task (not openclaw agent)
#   - MATON_API_KEY is inherited from the agent session's skill env injection
#   - Every action appears in the session transcript automatically
#
# Pipeline: fetch → classify → mark_processed → route_and_act
#
# Telegram approval for needs_reply is out-of-band:
# route-and-act.sh sends a Telegram preview; user taps Approve →
# send-approved-reply.sh runs separately.

name: email-triage
description: "Classify one email and take the appropriate action"

args:
  email_id:
    default: ""

env:
  TRIAGE_SCRIPTS_DIR: "/Users/aiagnet/.openclaw/workspace/scripts"
  TRIAGE_RULES_PATH: "/Users/aiagnet/.openclaw/workspace/memory/triage-rules.md"
  DRAFTS_FILE: "/Users/aiagnet/.openclaw/workspace/data/pending-drafts.json"
  # MATON_API_KEY is inherited from the parent agent session's environment.
  # It is injected by OpenClaw via skills.entries.gmail.env in openclaw.json.
  # No need to re-declare it here — it flows through automatically.

steps:
  # ── Step 1: Fetch email via Maton API Gateway → structured JSON ───
  - id: fetch_message
    command: |-
      bash "$TRIAGE_SCRIPTS_DIR/fetch-email.sh" "${email_id}"

  # ── Step 2: Classify into one of 5 buckets ───────────────────────
  # Uses openclaw.invoke --tool llm-task (available inside agent session).
  # triage-rules.md injected inline. AGENTS.md + soul.md in agent context.
  - id: classify
    stdin: $fetch_message.stdout
    command: |-
      bash "$TRIAGE_SCRIPTS_DIR/classify-email.sh"

  # ── Step 3: Apply Triage/Processed label (always, non-blocking) ──
  - id: mark_processed
    stdin: $classify.stdout
    command: |-
      bash "$TRIAGE_SCRIPTS_DIR/mark-processed.sh" "${email_id}"

  # ── Step 4: Route based on bucket ────────────────────────────────
  # spam_junk     → trash
  # newsletter    → label
  # notification  → label
  # needs_reply   → label + draft + Gmail draft + Telegram approval gate
  # review        → label + Telegram heads-up
  - id: route_and_act
    stdin: $mark_processed.stdout
    command: |-
      bash "$TRIAGE_SCRIPTS_DIR/route-and-act.sh" "${email_id}"
