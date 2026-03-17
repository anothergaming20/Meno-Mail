#!/usr/bin/env bash
# cleanup-stale-drafts.sh — Remove pending draft entries older than 48 hours.
# Scheduled via OpenClaw cron (daily at 3am).
set -euo pipefail

DRAFTS_FILE="${DRAFTS_FILE:-$HOME/.openclaw/workspace/data/pending-drafts.json}"

if [ ! -f "$DRAFTS_FILE" ]; then
  exit 0
fi

# macOS date uses -v for relative offsets
CUTOFF=$(date -u -v-48H +"%Y-%m-%dT%H:%M:%SZ")

# Remove entries with created_at older than cutoff
BEFORE=$(jq 'length' "$DRAFTS_FILE")
jq --arg cutoff "$CUTOFF" '
  with_entries(select(.value.created_at >= $cutoff))
' "$DRAFTS_FILE" > "${DRAFTS_FILE}.tmp" && mv "${DRAFTS_FILE}.tmp" "$DRAFTS_FILE"
AFTER=$(jq 'length' "$DRAFTS_FILE")

REMOVED=$((BEFORE - AFTER))
if [ "$REMOVED" -gt 0 ]; then
  echo "Cleaned up $REMOVED stale draft(s)."
fi
