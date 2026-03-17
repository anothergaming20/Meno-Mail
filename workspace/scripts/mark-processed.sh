#!/usr/bin/env bash
# mark-processed.sh — Apply the Triage/Processed label to prevent reprocessing.
set -euo pipefail
EMAIL_ID="$1"

source "${HOME}/.openclaw/workspace/data/label-ids.env"

gws gmail users messages modify \
  --params "$(jq -n --arg id "$EMAIL_ID" '{userId:"me",id:$id}')" \
  --json "{\"addLabelIds\":[\"${LABEL_TRIAGE_PROCESSED}\"]}" >/dev/null 2>&1

# Pass through stdin to stdout for downstream steps
cat
