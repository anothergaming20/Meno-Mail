#!/bin/bash
set -euo pipefail

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"
PENDING_DRAFTS="$DATA_DIR/pending-drafts.json"

echo "[cleanup-stale-drafts] Running at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ ! -f "$PENDING_DRAFTS" ]; then
  echo "[cleanup-stale-drafts] No pending-drafts.json found. Nothing to clean."
  exit 0
fi

# Compute cutoff timestamp (48 hours ago) in seconds since epoch
# macOS date uses -v flag for date arithmetic
CUTOFF_SECS=$(date -v-48H +%s 2>/dev/null || \
              date -d "48 hours ago" +%s 2>/dev/null || \
              echo "0")

CURRENT_DRAFTS=$(cat "$PENDING_DRAFTS" 2>/dev/null || echo "{}")

# Remove entries older than 48 hours
CLEANED=$(echo "$CURRENT_DRAFTS" | jq \
  --arg cutoff "$(date -v-48H -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d '48 hours ago' -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
  'with_entries(
    select(
      .value.created_at? and ($cutoff == "" or .value.created_at > $cutoff)
    )
  )' 2>/dev/null || echo "$CURRENT_DRAFTS")

BEFORE_COUNT=$(echo "$CURRENT_DRAFTS" | jq 'keys | length' 2>/dev/null || echo "0")
AFTER_COUNT=$(echo "$CLEANED" | jq 'keys | length' 2>/dev/null || echo "0")
REMOVED=$((BEFORE_COUNT - AFTER_COUNT))

echo "$CLEANED" > "${PENDING_DRAFTS}.tmp" && mv "${PENDING_DRAFTS}.tmp" "$PENDING_DRAFTS"

echo "[cleanup-stale-drafts] Removed $REMOVED stale draft(s). $AFTER_COUNT remaining."
