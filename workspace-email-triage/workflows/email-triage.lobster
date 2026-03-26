name: email-triage
description: "Classify one email, take action, and ingest to memory (Branch A/C)"

args:
  email_id:
    default: ""
  pre_classified_action:
    default: ""

env:
  TRIAGE_SCRIPTS_DIR: "~/.openclaw/workspace-email-triage/scripts"
  TRIAGE_RULES_PATH: "~/.openclaw/workspace-email-triage/memory/triage-rules.md"
  DRAFTS_FILE: "~/.openclaw/workspace-email-triage/data/pending-drafts.json"
  PRE_CLASSIFIED_ACTION: "${pre_classified_action}"

steps:
  - id: fetch_message
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/fetch-email.sh" "${email_id}"

  - id: classify
    stdin: $fetch_message.stdout
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/classify-email.sh"

  - id: mark_processed
    stdin: $classify.stdout
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/mark-processed.sh" "${email_id}"

  - id: route_and_act
    stdin: $classify.stdout
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/route-and-act.sh" "${email_id}"

  - id: ingest
    stdin: $fetch_message.stdout
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/ingest-email.sh"
