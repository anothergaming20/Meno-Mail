#!/usr/bin/env bash
# mark-processed.sh — Apply Triage/Processed label to prevent reprocessing. (v2.5)
# v2.5: Gmail calls via Maton API Gateway (MATON_API_KEY bearer token).
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

EMAIL_ID="$1"
MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

source "${HOME}/.openclaw/workspace/data/label-ids.env"

curl -sf -X POST \
  -H "Authorization: Bearer ${MATON_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"addLabelIds\":[\"${LABEL_TRIAGE_PROCESSED}\"]}" \
  "${MATON_BASE}/messages/${EMAIL_ID}/modify" >/dev/null 2>&1

# Pass stdin through to stdout for downstream Lobster steps
cat
