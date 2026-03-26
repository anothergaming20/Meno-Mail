#!/bin/bash
set -euo pipefail
# analyse-draft.sh — pure bash + jq risk analysis, no LLM, <200ms
# Input (stdin): {"email": {...}, "draft": "text"}
# Output (stdout): {"risk_flags": [...]}
# macOS compatible: uses grep -E instead of grep -P

export PATH="/usr/local/opt/node@22/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

WORKSPACE_TRIAGE=~/.openclaw/workspace-email-triage
DATA_DIR="$WORKSPACE_TRIAGE/data"

INPUT_JSON=$(cat)

DRAFT_TEXT=$(echo "$INPUT_JSON" | jq -r '.draft // ""' 2>/dev/null || echo "")
ORIGINAL_BODY=$(echo "$INPUT_JSON" | jq -r '.email.body_text // ""' 2>/dev/null || echo "")
FROM=$(echo "$INPUT_JSON" | jq -r '.email.from // ""' 2>/dev/null || echo "")

FLAGS=()

add_flag() {
  local CODE="$1"
  local SEVERITY="$2"
  local MESSAGE="$3"
  FLAGS+=("$(jq -n \
    --arg code "$CODE" \
    --arg severity "$SEVERITY" \
    --arg message "$MESSAGE" \
    '{code: $code, severity: $severity, message: $message}')")
}

# ── Signal 1: Monetary amount in draft not present in original ─────────────
# Use perl for regex extraction (macOS grep doesn't support -P/-o with PCRE)
DRAFT_AMOUNTS=$(echo "$DRAFT_TEXT" | \
  perl -ne 'while (/\$[0-9,]+(?:\.[0-9]{2})?/g) { print "$&\n" }' | sort -u || true)

if [ -n "$DRAFT_AMOUNTS" ]; then
  while IFS= read -r AMOUNT; do
    [ -z "$AMOUNT" ] && continue
    AMOUNT_NUM=$(echo "$AMOUNT" | tr -d '$,')
    if ! echo "$ORIGINAL_BODY" | grep -qF "$AMOUNT" 2>/dev/null && \
       ! echo "$ORIGINAL_BODY" | grep -qF "$AMOUNT_NUM" 2>/dev/null; then
      add_flag "new_monetary_amount" "red" \
        "Draft mentions $AMOUNT — original email did not contain this amount. Verify this is intentional."
    fi
  done <<< "$DRAFT_AMOUNTS"
fi

# ── Signal 2: Third-party name in draft not in original ───────────────────
# Extract capitalized words (potential names) using perl
DRAFT_NAMES=$(echo "$DRAFT_TEXT" | \
  perl -ne 'while (/\b([A-Z][a-z]{2,})\b/g) { print "$1\n" }' | \
  grep -vE '^(Dear|Hi|Hello|Thanks|Best|Regards|Sincerely|Thank|Please|Yes|No|Re|From|To|Subject|The|This|That|With|Your|You|Our|We|It|If|In|On|At|For|And|Or|But|As|By|Of)$' | \
  sort -u || true)

if [ -n "$DRAFT_NAMES" ]; then
  while IFS= read -r NAME; do
    [ -z "$NAME" ] && continue
    if ! echo "$ORIGINAL_BODY" | grep -qF "$NAME" 2>/dev/null && \
       ! echo "$FROM" | grep -qi "$NAME" 2>/dev/null; then
      if ! find "$WORKSPACE_TRIAGE/memory/people/" -name "*.md" \
           -exec grep -ql "$NAME" {} \; 2>/dev/null | head -1 | grep -q .; then
        add_flag "new_third_party" "amber" \
          "Draft mentions '$NAME' — this name does not appear in the original email or sender notes."
        break
      fi
    fi
  done <<< "$DRAFT_NAMES"
fi

# ── Signal 3: URL or file path in draft ────────────────────────────────────
URL_FOUND=$(echo "$DRAFT_TEXT" | \
  perl -ne 'if (/(https?:\/\/\S+)/) { print "$1\n"; last }' || true)
if [ -n "$URL_FOUND" ]; then
  add_flag "url_in_draft" "amber" \
    "Draft contains a URL: '$URL_FOUND'. Verify this is intentional."
fi

# ── Signal 4: Commitment verb + future date not in original ───────────────
COMMITMENT_VERBS="will|promise|commit|confirm|agree|guarantee|ensure"
DATE_PATTERNS="Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December|tomorrow|next week"

DRAFT_HAS_COMMITMENT=$(echo "$DRAFT_TEXT" | \
  grep -iE "\\b($COMMITMENT_VERBS)\\b" 2>/dev/null | \
  grep -iE "$DATE_PATTERNS" 2>/dev/null || true)

if [ -n "$DRAFT_HAS_COMMITMENT" ]; then
  ORIG_HAS_COMMITMENT=$(echo "$ORIGINAL_BODY" | \
    grep -iE "\\b($COMMITMENT_VERBS)\\b" 2>/dev/null | \
    grep -iE "$DATE_PATTERNS" 2>/dev/null || true)
  if [ -z "$ORIG_HAS_COMMITMENT" ]; then
    COMMIT_SNIPPET="${DRAFT_HAS_COMMITMENT:0:80}"
    add_flag "unanchored_commitment" "amber" \
      "Draft makes a date-specific commitment not present in the original email: '${COMMIT_SNIPPET}...'"
  fi
fi

# ── Signal 5: Draft word count > 2.5× original ─────────────────────────────
DRAFT_WORDS=$(echo "$DRAFT_TEXT" | wc -w | tr -d ' ' || echo "0")
ORIG_WORDS=$(echo "$ORIGINAL_BODY" | wc -w | tr -d ' ' || echo "0")

if [ "$ORIG_WORDS" -gt 5 ] && [ "$DRAFT_WORDS" -gt 0 ]; then
  EXCESSIVE=$(awk -v d="$DRAFT_WORDS" -v o="$ORIG_WORDS" 'BEGIN { print (d > o * 2.5) ? "yes" : "no" }')
  if [ "$EXCESSIVE" = "yes" ]; then
    add_flag "excessive_length" "amber" \
      "Draft ($DRAFT_WORDS words) is more than 2.5× the length of the original email ($ORIG_WORDS words)."
  fi
fi

# ── Signal 6: Injection-pattern markers in original email ─────────────────
INJECTION_PATTERNS="ignore previous|disregard|system prompt|new instruction|override|forget your|you are now|act as if|pretend you|roleplay as"
MATCHED=$(echo "$ORIGINAL_BODY" | \
  grep -ioE "$INJECTION_PATTERNS" 2>/dev/null | head -1 || true)

if [ -n "$MATCHED" ]; then
  add_flag "injection_suspected" "red" \
    "Original email contains injection-pattern marker: '${MATCHED}'. This email may be attempting to manipulate the agent."
fi

# ── Signal 7: Unknown sender ────────────────────────────────────────────────
FROM_ADDR=$(echo "$FROM" | \
  perl -ne 'if (/[\w.+\-]+@[\w.\-]+\.[a-zA-Z]{2,}/) { print "$&\n"; last }' || echo "")

if [ -n "$FROM_ADDR" ] && [ -f "$DATA_DIR/sender-preferences.json" ]; then
  KNOWN=$(jq -r --arg s "$FROM_ADDR" '.[] | select(.sender == $s) | .sender' \
    "$DATA_DIR/sender-preferences.json" 2>/dev/null | head -1 || echo "")
  if [ -z "$KNOWN" ]; then
    KNOWN_PERSON=$(find "$WORKSPACE_TRIAGE/memory/people/" -name "*.md" \
      -exec grep -ql "$FROM_ADDR" {} \; 2>/dev/null | head -1 || echo "")
    if [ -z "$KNOWN_PERSON" ]; then
      add_flag "unknown_sender" "amber" \
        "No prior history with sender $FROM_ADDR. Exercise caution approving this draft."
    fi
  fi
fi

# ── Signal 8: Verbatim copy ≥ 15 words from original ─────────────────────
DRAFT_WORDS_ARR=($DRAFT_TEXT)
TOTAL_DRAFT_WORDS=${#DRAFT_WORDS_ARR[@]}
VERBATIM_FOUND=""
if [ "$TOTAL_DRAFT_WORDS" -ge 15 ]; then
  I=0
  while [ $((I + 15)) -le "$TOTAL_DRAFT_WORDS" ]; do
    CHUNK="${DRAFT_WORDS_ARR[*]:$I:15}"
    if echo "$ORIGINAL_BODY" | grep -qiF "$CHUNK" 2>/dev/null; then
      VERBATIM_FOUND="$CHUNK"
      break
    fi
    I=$((I + 5))
  done
fi

if [ -n "$VERBATIM_FOUND" ]; then
  add_flag "verbatim_copy" "amber" \
    "Draft contains 15+ words copied verbatim from the original email. Verify this is intentional quoting."
fi

# ── Build output JSON ────────────────────────────────────────────────────────
if [ ${#FLAGS[@]} -eq 0 ]; then
  echo '{"risk_flags": []}'
else
  FLAGS_JSON=$(printf '%s\n' "${FLAGS[@]}" | jq -s '.')
  jq -n --argjson flags "$FLAGS_JSON" '{"risk_flags": $flags}'
fi
