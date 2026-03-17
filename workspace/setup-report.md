# Email Triage MVP — Setup Issues & Fixes

A running log of everything that broke during setup and how each was resolved.
Use this as a reference if setting up from scratch.

---

## 1. OpenClaw Config Merge (Phase 3)

### Issue A — Invalid keys in new OpenClaw version
The `openclaw-config-snippet.json5` included two keys that are no longer valid:
- `channels.telegram.chatId` — unrecognized in OpenClaw ≥ 2026.3.x
- `mcpServers` (root-level) — unrecognized in OpenClaw ≥ 2026.3.x

**Fix:** Skip both. The Telegram chat ID is handled via `groupAllowFrom`. The `gws` MCP server is not needed — scripts call `gws` directly as a shell command.

### Issue B — `lobster` and `llm-task` added to wrong tools key
The snippet says to use `tools.alsoAllow` (additive), but they were added to `tools.allow` (restrictive allowlist), which blocks all other tools.

**Fix:** Move `lobster` and `llm-task` to `tools.alsoAllow`:
```json
"tools": {
  "alsoAllow": ["lobster", "llm-task"]
}
```

---

## 2. Gmail Label Setup (Phase 4)

### Issue — `setup-labels.sh` exits with code 5
The script uses `set -euo pipefail`. When a label already exists (409 conflict), the fallback lookup uses `jq` with a filter that produces no output. In jq 1.7+, empty output returns exit code 5, which kills the script before any labels are looked up or written.

**Fix:** Skip the script entirely. Create labels and populate `label-ids.env` manually:
```bash
# Create labels
for LABEL in "Triage/Newsletter" "Triage/Notification" "Triage/NeedsReply" \
             "Triage/Review" "Triage/Approved" "Triage/Processed"; do
  gws gmail users labels create \
    --params '{"userId":"me"}' \
    --json "$(jq -n --arg name "$LABEL" \
      '{name:$name,labelListVisibility:"labelShow",messageListVisibility:"show"}')" \
    2>/dev/null | jq -r '"\(.name)\t\(.id)"'
done
```
Then write the IDs to `data/label-ids.env` manually.

---

## 3. Scripts Using Label Names Instead of IDs

### Issue — Gmail API rejects label names in `addLabelIds`
`mark-processed.sh` and `route-and-act.sh` used label names like `"Triage/Processed"` in `addLabelIds`. The Gmail API requires label IDs (e.g. `Label_33`).

**Fix:** Add `source "${HOME}/.openclaw/workspace/data/label-ids.env"` at the top of both scripts and replace all hardcoded label name strings with the env vars:
```bash
source "${HOME}/.openclaw/workspace/data/label-ids.env"
--json "{\"addLabelIds\":[\"${LABEL_TRIAGE_PROCESSED}\"]}"
```

---

## 4. gws OAuth Token Expiry (Recurring)

### Issue — 401 errors every ~7 days
GCP OAuth apps in **test mode** have refresh tokens that expire after 7 days. `gws auth status` may show `token_valid: true` locally while the API returns 401 — this happens when the cached access token expires and the refresh silently fails.

**Fix (temporary):** Re-authenticate weekly:
```bash
gws auth logout   # clear stale credentials first if needed
gws auth login -s gmail
```

**Fix (permanent):** Publish the GCP OAuth app out of test mode:
Google Cloud Console → APIs & Services → OAuth consent screen → **Publish App**.
No formal verification needed for personal/single-user apps.

---

## 5. `lobster: command not found`

### Issue — `lobster` is not a shell binary
The dispatcher called `lobster run --file email-triage.lobster` directly from bash. `lobster` is an OpenClaw agent tool (plugin), not a standalone CLI binary — it only exists inside an agent context.

**Fix:** Rewrote `dispatcher.sh` to run the pipeline steps inline in bash (`fetch → classify → mark-processed → route-and-act`) without calling lobster at all.

---

## 6. `openclaw.invoke: command not found`

### Issue — `openclaw.invoke` is also agent-internal
`classify-email.sh` and `draft-reply.sh` called `openclaw.invoke --tool llm-task` and `route-and-act.sh` called `openclaw.invoke --tool message`. Neither is available as a shell command.

**Fix A (LLM calls):** Replace `openclaw.invoke --tool llm-task` with `openclaw agent`:
```bash
RESPONSE=$(openclaw agent --agent main \
  --session-id "triage-classify-$$" \
  --model anthropic/claude-haiku-4-5-20251001 \
  --message "..." \
  --json 2>/dev/null)
RAW=$(echo "$RESPONSE" | jq -r '.result.payloads[0].text // empty')
```

**Fix B (Telegram messaging):** Replace `openclaw.invoke --tool message` with:
```bash
openclaw message send \
  --channel telegram \
  --target "YOUR_CHAT_ID" \
  --message "..."
```

---

## 7. Telegram `--target` Missing

### Issue — `openclaw message send` requires explicit `--target`
Both in `route-and-act.sh` and the OpenClaw cron jobs, Telegram sends failed with:
`error: required option '-t, --target <dest>' not specified`

**Fix:** Always pass `--target <chatId>` to `openclaw message send`, and add `--to <chatId>` when creating cron jobs:
```bash
openclaw cron add ... --to YOUR_CHAT_ID
# or fix existing:
openclaw cron edit <job-id> --to YOUR_CHAT_ID
```

---

## 8. Cron Jobs Sending Idle Telegram Reports

### Issue — `--announce` fires on every run, including "no emails" runs
Every 15-minute cron cycle sent a Telegram message even when the inbox was empty, causing notification spam.

**Fix:** Remove `--announce` from the cron job (`--no-deliver`), and add Telegram notification logic directly in `dispatcher.sh` — only fires when `COUNT > 0` or there are errors:
```bash
if [ $COUNT -gt 0 ] || [ $ERRORS -gt 0 ]; then
  openclaw message send --channel telegram --target "YOUR_CHAT_ID" \
    --message "📧 Email Triage Done\n✅ $COUNT processed"
fi
```

---

## 9. Cron Jobs Using Opus 4.6 (Expensive)

### Issue — Default model is claude-opus-4-6 (~$2.70/day idle)
The cron jobs inherited `agents.defaults.model = anthropic/claude-opus-4-6`. With 96 runs/day and ~11,400 tokens per idle run, cost was ~$81/month just for "no new emails" checks.

**Cost breakdown per idle run:**

| Model | Per run | Per day | Per month |
|---|---|---|---|
| Opus 4.6 (default) | ~$0.028 | ~$2.70 | ~$81 |
| Haiku 4.5 (fixed) | ~$0.002 | ~$0.18 | ~$5.50 |

**Fix:** Switch all triage jobs to Haiku:
```bash
openclaw cron edit <dispatcher-id> --model anthropic/claude-haiku-4-5-20251001
openclaw cron edit <cleanup-id>    --model anthropic/claude-haiku-4-5-20251001
```
And add `--model anthropic/claude-haiku-4-5-20251001` to `openclaw agent` calls in `classify-email.sh` and `draft-reply.sh`.

---

## 10. Draft Replies Not Saved to Gmail Drafts

### Issue — Drafts stored only in local JSON, invisible in Gmail
`route-and-act.sh` stored draft text in `data/pending-drafts.json` only. Gmail's Drafts folder was never used, so drafts were invisible to the user.

**Fix:** After generating the draft text, create a real Gmail draft via the Drafts API:
```bash
GMAIL_DRAFT_ID=$(gws gmail users drafts create \
  --params '{"userId":"me"}' \
  --json "$(jq -n --arg raw "$ENCODED_MSG" --arg tid "$THREAD_ID" \
    '{message:{raw:$raw,threadId:$tid}}')" \
  2>/dev/null | jq -r '.id // empty')
```
Store `gmail_draft_id` in `pending-drafts.json`. Update `send-approved-reply.sh` to use `gws gmail users drafts send` instead of `messages.send`.

---

## 11. Draft Replies Not Threaded

### Issue — `In-Reply-To` used Gmail's internal ID, not RFC 2822 Message-ID
The draft RFC 2822 message set `In-Reply-To` and `References` to Gmail's internal message ID (e.g. `19cf24b7...`). Gmail uses the RFC 2822 `Message-ID` header (e.g. `<uuid@Spark>`) for threading, so replies appeared as separate conversations.

**Fix A:** Add `message_id` extraction in `fetch-email.sh`:
```bash
message_id: ((.payload.headers // [])[] | select(.name == "Message-ID" or .name == "Message-Id") | .value),
```

**Fix B:** Use it in `route-and-act.sh` when building the draft:
```bash
RFC_MESSAGE_ID=$(echo "$INPUT" | jq -r '.email.message_id // ""')
RAW_MSG=$(printf "To: %s\r\nSubject: Re: %s\r\nIn-Reply-To: %s\r\nReferences: %s\r\n..." \
  "$FROM" "$SUBJECT" "$RFC_MESSAGE_ID" "$RFC_MESSAGE_ID" "$DRAFT_TEXT")
```

---

## Quick-Reference Checklist for Fresh Setup

- [ ] Use `tools.alsoAllow`, not `tools.allow`, for lobster/llm-task
- [ ] Skip `mcpServers` and `channels.telegram.chatId` — both invalid in new OpenClaw
- [ ] Create Gmail labels manually if `setup-labels.sh` exits with code 5
- [ ] Populate `data/label-ids.env` with real label IDs before running scripts
- [ ] Publish GCP OAuth app out of test mode to avoid 7-day token expiry
- [ ] Pass `--target <chatId>` to every `openclaw message send` call
- [ ] Pass `--to <chatId>` when creating OpenClaw cron jobs
- [ ] Use `--model anthropic/claude-haiku-4-5-20251001` for triage cron jobs
- [ ] Use `--no-deliver` on dispatcher cron; handle Telegram notify in the script
- [ ] Extract `message_id` from email headers for proper reply threading
- [ ] Create Gmail drafts via `users.drafts.create`, not just local JSON
