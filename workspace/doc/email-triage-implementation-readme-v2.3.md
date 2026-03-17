# Email Triage MVP — Implementation README

> Everything you need to set up, what to provide, and the exact steps to go live.
>
> **Host**: Mac Mini M4
> **Auth**: Personal Gmail (`@gmail.com`) via OAuth2 Desktop app
> **Scheduling**: OpenClaw's built-in Gateway cron (no launchd, no crontab)

---

## Part 1: What You Need to Provide


| #   | Item                          | Where to get it                                                                                             |
| --- | ----------------------------- | ----------------------------------------------------------------------------------------------------------- |
| 1   | **Google Cloud Project**      | [console.cloud.google.com](https://console.cloud.google.com) — create one or use existing, enable Gmail API |
| 2   | **OAuth2 Client Secret JSON** | GCP Console → Credentials → OAuth client ID → Desktop app → Download JSON                                   |
| 3   | **Telegram Bot Token**        | Message [@BotFather](https://t.me/BotFather) → `/newbot`                                                    |
| 4   | **Your Telegram Chat ID**     | Message your bot, then `curl https://api.telegram.org/bot<TOKEN>/getUpdates` → find `chat.id`               |


### Confirm your Mac Mini has these running

- OpenClaw (Gateway running)
- Claude connected
- QMD running (`qmd status`)
- Node.js 22+ via `node@22` tap (`/usr/local/opt/node@22/bin/node --version` → v22.x) — OpenClaw and Lobster require v22.12+
- `gws` CLI installed (`npm i -g @googleworkspace/cli && gws --version`)
- `lobster` CLI installed (`npm i -g @clawdbot/lobster && lobster --version`) — used by dispatcher.sh to orchestrate the per-email pipeline
- `jq` installed (`brew install jq` if missing)

---

## Part 2: What's in This Package

```
~/.openclaw/workspace/
├── scripts/
│   ├── dispatcher.sh              # Fetches email IDs; calls `lobster run` per email (Lobster orchestrates pipeline)
│   ├── fetch-email.sh             # Fetches one email by ID → JSON; extracts RFC 2822 message_id
│   ├── classify-email.sh          # Classifies via email-triage agent (Haiku) → 5 buckets
│   ├── draft-reply.sh             # Drafts replies via email-triage agent (Haiku) for needs_reply emails
│   ├── mark-processed.sh          # Applies Triage/Processed label (uses label IDs from label-ids.env)
│   ├── route-and-act.sh           # Routing — label/trash/draft/escalate (uses label IDs, creates Gmail draft)
│   ├── send-approved-reply.sh     # Sends reply after Telegram approval (uses gmail_draft_id)
│   ├── setup-labels.sh            # DO NOT USE — has jq exit 5 bug; create labels manually (see Phase 4)
│   └── cleanup-stale-drafts.sh    # Daily: removes pending drafts older than 48h
├── workflows/
│   └── email-triage.lobster       # Lobster workflow — orchestrates fetch→classify→mark_processed→route_and_act per email
├── memory/
│   └── triage-rules.md            # Classification rules, sender lists, reply style
├── data/
│   ├── pending-drafts.json        # Ephemeral draft storage; includes gmail_draft_id per entry
│   └── label-ids.env              # Gmail label ID mapping (written manually after label creation)
```

No launchd plists, no crontab entries. Scheduling lives inside OpenClaw.

### How It All Connects — Pipeline Diagram

```
OpenClaw Cron (every 15 min)
    └─→ dispatcher.sh
            ├─ gws gmail messages list  (fetch unprocessed inbox IDs)
            └─ for each email ID:
                 lobster run --file email-triage.lobster --args-json '{"email_id":"..."}'
                     │
                     ├─ [Lobster step: fetch_message]
                     │       fetch-email.sh → JSON (subject, body, from, message_id)
                     │
                     ├─ [Lobster step: classify]  ← stdin: fetch_message output
                     │       classify-email.sh → openclaw agent --agent email-triage (Haiku)
                     │       → bucket: spam_junk | newsletter | notification | needs_reply | review
                     │
                     ├─ [Lobster step: mark_processed]  ← stdin: classify output
                     │       mark-processed.sh → gws apply Triage/Processed label
                     │
                     └─ [Lobster step: route_and_act]  ← stdin: classify output
                             route-and-act.sh
                             ├─ spam_junk    → gws trash
                             ├─ newsletter   → gws apply Triage/Newsletter label
                             ├─ notification → gws apply Triage/Notification label
                             ├─ needs_reply  → draft-reply.sh (Haiku)
                             │                 gws gmail drafts create
                             │                 openclaw message send (Telegram: approve/dismiss)
                             └─ review       → openclaw message send (Telegram: review link)
```

---

## Part 3: Step-by-Step Implementation

### Phase 0 — Install CLI tools

```bash
# Google Workspace CLI (Gmail API wrapper)
npm i -g @googleworkspace/cli
gws --version

# Lobster workflow orchestrator (required — dispatcher.sh calls lobster run per email)
npm i -g @clawdbot/lobster
lobster --version

# jq (JSON processor used throughout all scripts)
brew install jq   # skip if already installed
```

> **Node.js version**: Both `gws` and `lobster` require Node.js 22+. If `node --version` shows v20 or lower, install via `brew install node@22` and ensure `/usr/local/opt/node@22/bin` is on your PATH. All scripts include `export PATH="/usr/local/opt/node@22/bin:$PATH"` as a safeguard.

### Phase 1 — Google Cloud + Gmail Auth

Everything happens directly on the Mac Mini.

1. **Create GCP project** (if needed) and **enable Gmail API**:
  - [console.cloud.google.com](https://console.cloud.google.com) → create/select project
  - APIs & Services → Library → "Gmail API" → Enable
2. **Configure OAuth consent screen**:
  - APIs & Services → OAuth consent screen → External, testing mode
  - Fill in app name (e.g. "Email Triage Agent")
3. **Add yourself as a test user**:
  - OAuth consent screen → Test users → Add your `@gmail.com`
4. **Create OAuth client credentials**:
  - Credentials → Create Credentials → OAuth client ID → **Desktop app**
  - Download JSON → save as `~/.config/gws/client_secret.jsonlobster`
5. **Authenticate**:
  ```bash
   gws auth login -s gmail
  ```
6. **Verify**:
  ```bash
   gws gmail users messages list --params '{"userId":"me","maxResults":3}'
  ```

### Phase 2 — Telegram Bot

1. **Create bot**: Message @BotFather → `/newbot` → copy token.
2. **Get chat ID**:
  ```bash
   curl -s https://api.telegram.org/bot<TOKEN>/getUpdates | jq '.result[0].message.chat.id'
  ```
3. **Store token**:
  ```bash
   mkdir -p ~/.openclaw/secrets
   echo "YOUR_BOT_TOKEN" > ~/.openclaw/secrets/telegram-bot-token
   chmod 600 ~/.openclaw/secrets/telegram-bot-token
  ```

### Phase 3 — OpenClaw Configuration

Merge these settings into your `openclaw.json`:

```json
{
  "plugins": {
    "entries": {
      "lobster": { "enabled": true },
      "llm-task": {
        "enabled": true,
        "config": {
          "defaultProvider": "anthropic",
          "defaultModel": "claude-haiku-4-5-20251001",
          "maxTokens": 800,
          "timeoutMs": 30000
        }
      }
    }
  },
  "tools": {
    "alsoAllow": ["lobster", "llm-task"]
  },
  "agents": {
    "list": [
      { "id": "main" },
      {
        "id": "email-triage",
        "name": "email-triage",
        "workspace": "~/.openclaw/workspace",
        "agentDir": "~/.openclaw/agents/email-triage/agent",
        "model": "anthropic/claude-haiku-4-5-20251001"
      }
    ]
  },
  "cron": { "enabled": true }
}
```

**Important**: Do NOT add `agents.list` manually to `openclaw.json`. Instead, use the CLI to create the agent:

```bash
openclaw agents add email-triage \
  --model "anthropic/claude-haiku-4-5-20251001" \
  --workspace "/Users/aiagnet/.openclaw/workspace" \
  --non-interactive
```

This command registers the agent in `openclaw.json` under `agents.list` with the correct schema and creates the agent directory at `~/.openclaw/agents/email-triage/`. The `email-triage` agent uses `anthropic/claude-haiku-4-5-20251001` (not the default Opus). Both `classify-email.sh` and `draft-reply.sh` call `openclaw agent --agent email-triage` to route all LLM work through this dedicated agent.

**Critical: do NOT add the following** — they are invalid in OpenClaw ≥ 2026.3.x and will cause a validation error at startup:

- `mcpServers` — `gws` is called directly as a shell command, not via MCP
- `channels.telegram.chatId` — the chat ID is configured via `groupAllowFrom` in the existing Telegram channel config

**Use `tools.alsoAllow`, never `tools.allow`** — `tools.allow` puts OpenClaw in restrictive allowlist mode and blocks core tools.

### Phase 4 — Create Gmail Labels

**Do NOT run `setup-labels.sh`** — it has a bug: with `set -euo pipefail`, when `jq` produces empty output (no match) it exits with code 5, killing the script before it completes. Create labels manually instead:

```bash
for LABEL in "Triage/Newsletter" "Triage/Notification" "Triage/NeedsReply" "Triage/Review" "Triage/Approved" "Triage/Processed"; do
  echo -n "Creating $LABEL ... "
  gws gmail users labels create \
    --params '{"userId":"me"}' \
    --json "$(jq -n --arg name "$LABEL" '{name:$name,labelListVisibility:"labelShow",messageListVisibility:"show"}')" \
    2>/dev/null | jq -r '"\(.id // .error.message)"'
done
```

Each command prints the label ID (e.g. `Label_28`). Write these IDs to `data/label-ids.env` manually:

```bash
mkdir -p ~/.openclaw/workspace/data
cat > ~/.openclaw/workspace/data/label-ids.env <<'EOF'
LABEL_TRIAGE_NEWSLETTER="Label_28"
LABEL_TRIAGE_NOTIFICATION="Label_29"
LABEL_TRIAGE_NEEDSREPLY="Label_30"
LABEL_TRIAGE_REVIEW="Label_31"
LABEL_TRIAGE_APPROVED="Label_32"
LABEL_TRIAGE_PROCESSED="Label_33"
EOF
```

Replace the `Label_*` values with the actual IDs returned by your create commands — the IDs will differ on every system.

### Phase 5 — Deploy Files + Apply Script Patches

```bash
mkdir -p ~/.openclaw/workspace/{scripts,workflows,memory,data}

# Copy files from unzipped package
cp email-triage-mvp/scripts/*.sh       ~/.openclaw/workspace/scripts/
cp email-triage-mvp/workflows/*.lobster ~/.openclaw/workspace/workflows/
cp email-triage-mvp/memory/*.md         ~/.openclaw/workspace/memory/

chmod +x ~/.openclaw/workspace/scripts/*.sh
echo '{}' > ~/.openclaw/workspace/data/pending-drafts.json
```

**All patches are already applied** in the scripts in this repo. If deploying from an older package, the following changes were required (listed for reference):

1. `mark-processed.sh` and `route-and-act.sh`: source `label-ids.env`; use `${LABEL_TRIAGE_*}` variables — Gmail API requires label IDs, not names.
2. `classify-email.sh` and `draft-reply.sh`: replaced `openclaw.invoke --tool llm-task` with `openclaw agent --agent email-triage --session-id "triage-$$" --json`. No `--model` flag — model is set in `agents.list`.
3. `route-and-act.sh`: replaced `openclaw.invoke --tool message` with `openclaw message send --channel telegram --target "CHAT_ID"`.
4. `route-and-act.sh`: added `gws gmail users drafts create` call; stores `gmail_draft_id` in `pending-drafts.json`.
5. `send-approved-reply.sh`: uses `gws gmail users drafts send --json '{"id":"DRAFT_ID"}'` with stored `gmail_draft_id`; falls back to raw message construction if no draft ID.
6. `fetch-email.sh`: extracts `Message-ID` header as `message_id` (RFC 2822).
7. `route-and-act.sh`: uses RFC 2822 `message_id` in `In-Reply-To`/`References` headers.
8. `dispatcher.sh`: query uses `newer_than:30d`, `maxResults:50`; Telegram notification only fires when `COUNT > 0`.
9. All scripts: `export PATH="/usr/local/opt/node@22/bin:$PATH"` at top — prevents login shell from overriding `node` to v20.

### Phase 6 — Customize Triage Rules

Edit `~/.openclaw/workspace/memory/triage-rules.md`:

1. **Add your VIP senders** — people who always get a reply
2. **Add your specific spam patterns**
3. **Add your newsletter senders**
4. **Tweak the reply style guide**

Verify QMD indexes it:

```bash
qmd search "triage rules" -c workspace
```

### Phase 7 — Schedule with OpenClaw Cron

Two commands — no plists, no crontab, no launchd.

```bash
# Email triage dispatcher — every 15 minutes
openclaw cron add \
  --name "email-triage-dispatcher" \
  --description "Fetch, classify, and act on new inbox emails" \
  --every 15m \
  --session isolated \
  --light-context \
  --message "Run the email triage dispatcher: bash ~/.openclaw/workspace/scripts/dispatcher.sh — then briefly report how many emails were processed and any errors." \
  --no-deliver \
  --model anthropic/claude-haiku-4-5-20251001 \
  --to YOUR_TELEGRAM_CHAT_ID

# Stale draft cleanup — daily at 3:17am
openclaw cron add \
  --name "email-triage-cleanup" \
  --description "Purge pending draft entries older than 48h" \
  --cron "17 3 * * *" \
  --session isolated \
  --light-context \
  --message "Run the stale draft cleanup: bash ~/.openclaw/workspace/scripts/cleanup-stale-drafts.sh — report how many drafts were removed." \
  --announce \
  --channel telegram \
  --to YOUR_TELEGRAM_CHAT_ID \
  --model anthropic/claude-haiku-4-5-20251001 \
  --tz "America/New_York"
```

**What these flags do**:

- `--session isolated` — runs in its own session, no clutter in your main chat
- `--light-context` — skips workspace bootstrap injection (these are lightweight chores)
- `--no-deliver` on dispatcher — Telegram notification is handled inside `dispatcher.sh` directly via `openclaw message send`; OpenClaw's own deliver mechanism is not used for the dispatcher
- `--announce` on cleanup — cleanup uses OpenClaw's deliver mechanism to send its report to Telegram
- `--model anthropic/claude-haiku-4-5-20251001` — required on both; without it, OpenClaw defaults to a heavier model (~$81/month idle vs. ~$5.50/month with Haiku)
- `--to YOUR_TELEGRAM_CHAT_ID` — required on both jobs

**Verify**:

```bash
openclaw cron list
```

**Manage**:

```bash
# View run history
openclaw cron runs --id <job-id>

# Manually trigger a run
openclaw cron run <job-id>

# Temporarily disable
openclaw cron edit <job-id> --disable

# Re-enable
openclaw cron edit <job-id> --enable
```

### Phase 8 — Smoke Tests


| #   | Test                                      | Expected result                                                             |
| --- | ----------------------------------------- | --------------------------------------------------------------------------- |
| 1   | Email from a VIP address                  | Labeled `Triage/NeedsReply` + Telegram with draft + approve/dismiss buttons |
| 2   | Email from a known spam pattern           | Auto-trashed, no Telegram notification                                      |
| 3   | Newsletter-style email                    | Labeled `Triage/Newsletter`, stays in inbox                                 |
| 4   | Ambiguous email from unknown sender       | Labeled `Triage/Review` + Telegram notification with Gmail link             |
| 5   | Tap "Approve" on a draft in Telegram      | Reply sent from Gmail, labeled `Triage/Approved`                            |
| 6   | Run `dispatcher.sh` twice quickly         | Second run skips (lockfile guard)                                           |
| 7   | Check `pending-drafts.json` after approve | Entry is deleted                                                            |


**If a test fails**: Check run history with `openclaw cron runs --id <job-id>`. Common issues:

- "API not enabled" → enable Gmail API in GCP Console
- "Access blocked" → add yourself as test user in OAuth consent screen
- Label errors → Gmail API uses label IDs not names; check `data/label-ids.env`
- Auth errors → re-run `gws auth login -s gmail`; see Notes on 7-day token expiry

---

## Part 4: What I Built vs. What You Customize


| File                         | Status                                                            | Your action                                                    |
| ---------------------------- | ----------------------------------------------------------------- | -------------------------------------------------------------- |
| All scripts (`scripts/*.sh`) | Ready (requires post-deploy patches — see Phase 5)                | Apply patches before first run                                 |
| `email-triage.lobster`       | **Used at runtime** — Lobster orchestrates the per-email pipeline | No action needed — dispatcher.sh calls `lobster run` per email |
| `triage-rules.md`            | **Needs your input**                                              | Add VIP senders, review spam patterns, adjust reply style      |
| OpenClaw cron jobs           | **You run 2 commands**                                            | Phase 7 above                                                  |
| OAuth credentials            | **You generate**                                                  | `gws auth login -s gmail`                                      |
| Telegram bot token           | **You generate**                                                  | From @BotFather                                                |
| `data/label-ids.env`         | **You write manually**                                            | After running the Phase 4 label creation loop                  |


---

## Part 5: Notes

**Why OpenClaw cron, not launchd or crontab?** OpenClaw's Gateway scheduler persists jobs, handles retries with exponential backoff, logs run history, and integrates with the agent runtime. One less thing to manage outside OpenClaw.

**gws OAuth token expiry — critical warning for test mode**: GCP OAuth apps in **test mode** issue refresh tokens that expire after **7 days**. `gws` does NOT auto-refresh after this 7-day limit — auth will break silently. Weekly manual refresh required: `gws auth logout && gws auth login -s gmail`. To eliminate this permanently: publish the OAuth app in GCP Console → APIs & Services → OAuth consent screen → Publish App. Once published, refresh tokens no longer have a 7-day expiry.

`**gmail.send` scope**: Required by `send-approved-reply.sh`. If not already included in your initial auth, re-run `gws auth login -s gmail` (will include send scope).

**Model cost**: Both classify and draft use the `email-triage` agent configured with `claude-haiku-4-5-20251001`. Original spec had Sonnet for drafts — changed to Haiku for both to reduce cost. Haiku idle cost is ~$5.50/month vs. ~$81/month for Opus at the cron poll rate. Draft quality with Haiku is acceptable for most reply scenarios.

**Dedicated `email-triage` agent**: Created via `openclaw agents add email-triage --model "anthropic/claude-haiku-4-5-20251001"`. Both `classify-email.sh` and `draft-reply.sh` call `openclaw agent --agent email-triage` — no `--model` flag on the CLI; model is set in `agents.list` entry.

**OpenClaw cron retry policy**: If a dispatcher run fails (API error, network issue), OpenClaw applies exponential backoff (30s → 1m → 5m → 15m → 60m) and retries automatically. Backoff resets after the next success.

`**lobster` as a shell binary**: `lobster` (`@clawdbot/lobster`) is installed at `/usr/local/opt/node@22/bin/lobster` and called directly from `dispatcher.sh`. Steps inside workflows execute via `/bin/sh -lc` — all scripts that call `openclaw` must include `export PATH="/usr/local/opt/node@22/bin:$PATH"` to avoid node version issues.

`**openclaw.invoke` from shell**: `openclaw.invoke` is agent-internal — not a shell command. All LLM calls use `openclaw agent --agent email-triage`; Telegram messages use `openclaw message send --channel telegram --target "CHAT_ID"`.