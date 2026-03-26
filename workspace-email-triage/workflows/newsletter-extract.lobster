name: newsletter-extract
description: "Extract articles, score relevance, and write knowledge memory notes from a newsletter email"

args:
  email_id:
    default: ""

env:
  TRIAGE_SCRIPTS_DIR: "~/.openclaw/workspace-email-triage/scripts"
  MEMORY_PATH: "~/.openclaw/workspace-newsletter/memory"

steps:
  - id: fetch_full_body
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/fetch-email.sh" "${email_id}" --full-body

  - id: extract_and_score
    stdin: $fetch_full_body.stdout
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/ingest-branch-b.sh"

  - id: write_memory
    stdin: $extract_and_score.stdout
    command: |-
      bash "$HOME/.openclaw/workspace-email-triage/scripts/export-sender-digest.sh" --knowledge-only
