#!/bin/bash
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
LABEL_IDS_FILE="$DATA_DIR/label-ids.env"

MATON_BASE="https://gateway.maton.ai/google-mail/gmail/v1/users/me"

echo "[setup-labels] Creating Gmail labels via Maton API..."

# Six required labels
LABELS=(
  "Triage/Newsletter"
  "Triage/Notification"
  "Triage/NeedsReply"
  "Triage/Review"
  "Triage/Approved"
  "Triage/Processed"
)

# Map label name to env var name (bash 3.2 compatible — no associative arrays)
label_var_name() {
  case "$1" in
    "Triage/Newsletter")   echo "LABEL_TRIAGE_NEWSLETTER" ;;
    "Triage/Notification") echo "LABEL_TRIAGE_NOTIFICATION" ;;
    "Triage/NeedsReply")   echo "LABEL_TRIAGE_NEEDSREPLY" ;;
    "Triage/Review")       echo "LABEL_TRIAGE_REVIEW" ;;
    "Triage/Approved")     echo "LABEL_TRIAGE_APPROVED" ;;
    "Triage/Processed")    echo "LABEL_TRIAGE_PROCESSED" ;;
  esac
}

# Initialize or clear the label-ids.env file
mkdir -p "$DATA_DIR"
> "$LABEL_IDS_FILE"

for LABEL_NAME in "${LABELS[@]}"; do
  # First, check if label already exists
  SEARCH_RESPONSE=$(curl -sf \
    -H "Authorization: Bearer $MATON_API_KEY" \
    "$MATON_BASE/labels" 2>/dev/null || echo "")

  EXISTING_ID=$(echo "$SEARCH_RESPONSE" | jq -r \
    --arg name "$LABEL_NAME" \
    '.labels[] | select(.name == $name) | .id' 2>/dev/null | head -1 || echo "")

  if [ -n "$EXISTING_ID" ]; then
    echo "[setup-labels] Label '$LABEL_NAME' already exists: $EXISTING_ID"
    LABEL_ID="$EXISTING_ID"
  else
    # Create the label
    CREATE_BODY=$(jq -n \
      --arg name "$LABEL_NAME" \
      '{
        "name": $name,
        "labelListVisibility": "labelShow",
        "messageListVisibility": "show"
      }')

    CREATE_RESPONSE=$(curl -sf -X POST \
      -H "Authorization: Bearer $MATON_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$CREATE_BODY" \
      "$MATON_BASE/labels" 2>/dev/null || echo "")

    LABEL_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id // ""' 2>/dev/null || echo "")

    if [ -z "$LABEL_ID" ]; then
      echo "[setup-labels] ERROR: Failed to create label '$LABEL_NAME'" >&2
      echo "[setup-labels] Response: $CREATE_RESPONSE" >&2
      continue
    fi

    echo "[setup-labels] Created label '$LABEL_NAME': $LABEL_ID"
  fi

  VAR_NAME=$(label_var_name "$LABEL_NAME")
  echo "${VAR_NAME}=${LABEL_ID}" >> "$LABEL_IDS_FILE"
done

echo "[setup-labels] Done. Label IDs written to $LABEL_IDS_FILE"
echo ""
cat "$LABEL_IDS_FILE"
