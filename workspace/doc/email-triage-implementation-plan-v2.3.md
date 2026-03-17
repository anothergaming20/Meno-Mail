# Email Triage MVP — Implementation Plan

> Mac Mini M4 · OpenClaw · Main agent: Opus 4.6 · Email-triage agent: Haiku (claude-haiku-4-5-20251001)
> Last updated: 2026-03-14

---

## How to Use This File

- Paste the **Session Header** block at the top of each new Claude conversation to orient Claude instantly
- Check off steps as you complete them
- Update the **Current Status** section after each session
- Keep this file in `~/.openclaw/workspace/email-triage-implementation-plan.md` for easy access

---

## Current Status

```
Phase 0 (Pre-work):        [x] Complete
Phase 1 (GCP + Gmail):     [x] Complete
Phase 2 (Telegram):        [x] Complete
Phase 3 (OpenClaw config): [x] Complete
Phase 4 (Gmail labels):    [x] Complete
Phase 5 (Deploy files):    [x] Complete
Phase 6 (Triage rules):    [x] Complete
Phase 7 (Cron jobs):       [x] Complete
Phase 8 (Smoke tests):     [x] Complete
```

---

## Interface Guide


| Task type                                              | Use                                |
| ------------------------------------------------------ | ---------------------------------- |
| Planning, Q&A, config review                           | Claude Chat (claude.ai)            |
| Running scripts, editing files, troubleshooting errors | Claude Code (Terminal on Mac Mini) |
| Document/knowledge work                                | Cowork (not needed for this setup) |


**Claude Code setup** (run once on Mac Mini):

```bash
npm install -g @anthropic-ai/claude-code
claude  # sign in with claude.ai credentials
```

Point Claude Code at: `~/.openclaw/workspace/`

---

## Token Budget Rules (Claude Pro — 5hr rolling window)

1. **Start a new conversation for each session** — kills context accumulation
2. **Always paste the Session Header** at the start — never re-explain from scratch
3. **Don't re-upload zip or spec files** — paste only the relevant snippet when needed
4. **Batch terminal questions** — ask multiple things at once, not one by one
5. **For errors**: paste just the error message + the command that caused it, not the full script
6. **End every session** with: *"Summarize where we are, what's done, what's next, and any gotchas"* — save output to this file

---

## Session Breakdown

---

### Session 0 — Pre-Work (No Claude Needed)

> Browser + Terminal only. Zero tokens spent.

**Do this before any Claude session.**

#### Terminal

```bash
npm i -g @googleworkspace/cli
gws --version
brew install jq

# Unzip the package and verify structure
unzip email-triage-mvp.zip -d ~/email-triage-mvp
ls ~/email-triage-mvp/
```

#### GCP Console (browser — console.cloud.google.com)

- Create or select a GCP project
- APIs & Services → Library → search "Gmail API" → Enable
- APIs & Services → OAuth consent screen → External → Testing mode
  - App name: "Email Triage Agent"
- OAuth consent screen → Test users → Add your @gmail.com
- Credentials → Create Credentials → OAuth client ID → **Desktop app**
- Download JSON → save as `~/.config/gws/client_secret.json`

#### Telegram (phone/browser)

- Message @BotFather → `/newbot` → copy bot token
- Run to get your chat ID:
  ```bash
  curl -s https://api.telegram.org/bot<TOKEN>/getUpdates | jq '.result[0].message.chat.id'
  ```
- Store token:
  ```bash
  mkdir -p ~/.openclaw/secrets
  echo "YOUR_BOT_TOKEN" > ~/.openclaw/secrets/telegram-bot-token
  chmod 600 ~/.openclaw/secrets/telegram-bot-token
  ```

**Status when done:**

```
Phase 0: [x] Complete
Phase 1: [x] Complete
Phase 2: [x] Complete
```

---

### Session 1 — Config + Deploy

> Interface: **Claude Code** on Mac Mini
> Estimated messages: 15–20
> Covers: Phase 3, Phase 4, Phase 5

#### Session Header (paste at start of conversation)

```
## Email Triage Setup — Session 1
Phases 0–2 complete:
- gws and jq installed
- GCP project created, Gmail API enabled
- OAuth consent screen configured, myself added as test user
- Desktop OAuth client JSON downloaded to ~/.config/gws/client_secret.json
- Telegram bot created, token stored at ~/.openclaw/secrets/telegram-bot-token
- Chat ID: [YOUR_CHAT_ID]
- Package unzipped at ~/email-triage-mvp/

Starting Phase 3: OpenClaw config merge.
Working directory: ~/.openclaw/workspace/
```

#### Steps

- **Phase 3** — Merge the following into `openclaw.json`:
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
  **Do NOT add** `mcpServers` or `channels.telegram.chatId` — both are invalid in OpenClaw ≥ 2026.3.x and will cause a validation error. The Telegram chat ID is configured via `groupAllowFrom` in the existing Telegram channel config. `gws` is called directly as a shell command, not via MCP.

- **Add the email-triage agent** — Do NOT add `agents.list` manually to `openclaw.json`. Use the CLI:
  ```bash
  openclaw agents add email-triage \
    --model "anthropic/claude-haiku-4-5-20251001" \
    --workspace "/Users/aiagnet/.openclaw/workspace" \
    --non-interactive
  ```
  This registers the agent in `openclaw.json` under `agents.list` (the correct schema for this OpenClaw version) and creates `~/.openclaw/agents/email-triage/`. The agent uses `anthropic/claude-haiku-4-5-20251001` (cost-efficient, ~$5.50/month at 15-min cron) and shares the main workspace so it has QMD access to `triage-rules.md`. Both `classify-email.sh` and `draft-reply.sh` route all LLM calls through `--agent email-triage` instead of `--agent main`, keeping triage workloads isolated from the main agent. [x] Complete

- **Phase 4** — Create Gmail labels manually (do NOT run `setup-labels.sh` — it has a jq exit code 5 bug with `set -euo pipefail` that makes it unreliable):
  ```bash
  for LABEL in "Triage/Newsletter" "Triage/Notification" "Triage/NeedsReply" "Triage/Review" "Triage/Approved" "Triage/Processed"; do
    echo -n "Creating $LABEL ... "
    gws gmail users labels create \
      --params '{"userId":"me"}' \
      --json "$(jq -n --arg name "$LABEL" '{name:$name,labelListVisibility:"labelShow",messageListVisibility:"show"}')" \
      2>/dev/null | jq -r '"\(.id // .error.message)"'
  done
  ```
  Then write `data/label-ids.env` manually with the IDs returned (IDs will differ on your system):
  ```bash
  cat > ~/.openclaw/workspace/data/label-ids.env <<'EOF'
  LABEL_TRIAGE_NEWSLETTER="Label_28"
  LABEL_TRIAGE_NOTIFICATION="Label_29"
  LABEL_TRIAGE_NEEDSREPLY="Label_30"
  LABEL_TRIAGE_REVIEW="Label_31"
  LABEL_TRIAGE_APPROVED="Label_32"
  LABEL_TRIAGE_PROCESSED="Label_33"
  EOF
  ```
  Replace the `Label_*` values with the actual IDs returned by the create commands above.

- **Phase 5** — Deploy files
  ```bash
  mkdir -p ~/.openclaw/workspace/{scripts,workflows,memory,data}
  cp ~/email-triage-mvp/scripts/*.sh ~/.openclaw/workspace/scripts/
  cp ~/email-triage-mvp/workflows/*.lobster ~/.openclaw/workspace/workflows/
  cp ~/email-triage-mvp/memory/*.md ~/.openclaw/workspace/memory/
  chmod +x ~/.openclaw/workspace/scripts/*.sh
  echo '{}' > ~/.openclaw/workspace/data/pending-drafts.json
  ```
  Note: `email-triage.lobster` is **used at runtime**. `dispatcher.sh` calls `lobster run --file email-triage.lobster --args-json '{"email_id":"..."}'` for each email. The Lobster workflow orchestrates the fetch→classify→mark_processed→route_and_act steps with stdout piping between steps.

- **Script patches required after deploy** — the scripts need the following fixes before they will work correctly:
  - `mark-processed.sh` and `route-and-act.sh`: add `source $HOME/.openclaw/workspace/data/label-ids.env` at the top; replace label name strings with `${LABEL_TRIAGE_*}` variables — the Gmail API rejects label names and requires label IDs.
  - `classify-email.sh` and `draft-reply.sh`: replace `openclaw.invoke --tool llm-task` with `openclaw agent --agent email-triage --session-id "triage-$$" --json`. Model is set via the `agents.list` entry for `email-triage` — do not pass `--model` on the command line.
  - `route-and-act.sh`: replace `openclaw.invoke --tool message` with `openclaw message send --channel telegram --target "YOUR_CHAT_ID"`.
  - `route-and-act.sh`: add a `gws gmail users drafts create` call after generating the draft text, so the draft appears in Gmail's Drafts folder. Store the returned `gmail_draft_id` in the `pending-drafts.json` entry.
  - `send-approved-reply.sh`: use `gws gmail users drafts send --json '{"id":"DRAFT_ID"}'` with the stored `gmail_draft_id` instead of constructing a raw message.
  - `fetch-email.sh`: add extraction of the `Message-ID` header from the email payload, exposing it as `message_id` in the output JSON.
  - `route-and-act.sh`: use the RFC 2822 `message_id` (e.g. `<uuid@Spark>`) in `In-Reply-To` and `References` headers — not Gmail's internal message ID.
  - `dispatcher.sh`: change query from `newer_than:1h` to `newer_than:30d`, change `maxResults` from 20 to 50.
  - `dispatcher.sh`: send the Telegram count notification only when `COUNT > 0`.

- **Authenticate gws**
  ```bash
  gws auth login -s gmail
  # Verify:
  gws gmail users messages list --params '{"userId":"me","maxResults":3}'
  ```

**End-of-session prompt:** *"Summarize where we are, what's done, what's next, and any gotchas."*

**Status when done:**

```
Phase 3: [x] Complete
Phase 4: [x] Complete
Phase 5: [x] Complete
```

---

### Session 2 — Triage Rules

> Interface: **Claude Code** or **Chat** (either works — no bash needed)
> Estimated messages: 20–25 (most iterative session)
> Covers: Phase 6 only

#### Session Header (paste at start of conversation)

```
## Email Triage Setup — Session 2
Phases 0–5 complete:
- OpenClaw config merged
- Gmail labels created manually, label-ids.env populated
- All scripts deployed and chmod'd, post-deploy patches applied
- gws authenticated and verified
- pending-drafts.json initialized

Starting Phase 6: Customizing triage-rules.md
File location: ~/.openclaw/workspace/memory/triage-rules.md
```

#### Steps

Edit `~/.openclaw/workspace/memory/triage-rules.md` to add:

- **VIP senders** — people who always get a reply drafted
  - Examples: your boss, key clients, family, specific domains
- **Spam patterns** — auto-trash these without notification
  - Examples: marketing@*, noreply@*, known spam domains
- **Newsletter senders** — label as Newsletter, no action needed
  - Examples: substack digests, product update emails
- **Reply style guide** — how Haiku should write your draft replies
  - Tone: formal / casual / somewhere in between?
  - Sign-off: how you close emails
  - Anything to always/never say?

Verify QMD indexes the file:

```bash
qmd search "triage rules" -c workspace
```

**End-of-session prompt:** *"Summarize where we are, what's done, what's next, and any gotchas."*

**Status when done:**

```
Phase 6: [x] Complete
```

---

### Session 3 — Cron Jobs + Smoke Tests

> Interface: **Claude Code** on Mac Mini
> Estimated messages: 15–20 (mostly terminal, but keep budget for troubleshooting)
> Covers: Phase 7, Phase 8

#### Session Header (paste at start of conversation)

```
## Email Triage Setup — Session 3
Phases 0–6 complete:
- All config, files, auth, and labels done
- triage-rules.md customized and indexed by QMD

Starting Phase 7: OpenClaw cron job registration.
Then Phase 8: Smoke tests.
```

#### Phase 7 — Register Cron Jobs

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

# Verify both jobs registered
openclaw cron list
```

**Flag notes**:
- `--every 15m` — every 15 minutes (not 5; 5-minute polling caused too many idle API calls)
- `--model anthropic/claude-haiku-4-5-20251001` — required on both jobs; defaults to Opus otherwise (~$81/month idle vs. ~$5.50/month with Haiku)
- `--no-deliver` on dispatcher — Telegram notification is handled inside `dispatcher.sh` directly, not via OpenClaw's deliver mechanism
- `--announce` on cleanup — cleanup sends its own Telegram report via OpenClaw's deliver mechanism
- `--to YOUR_TELEGRAM_CHAT_ID` — must be included on both jobs

Both jobs registered in `openclaw cron list`.

#### Phase 8 — Smoke Tests

Run each test and confirm expected result:


| #   | Test                                        | Expected result                                                             | Pass? |
| --- | ------------------------------------------- | --------------------------------------------------------------------------- | ----- |
| 1   | Send email from a VIP address to yourself   | Labeled `Triage/NeedsReply` + Telegram with draft + approve/dismiss buttons | [ ]   |
| 2   | Send email from a known spam pattern        | Auto-trashed, no Telegram notification                                      | [ ]   |
| 3   | Send a newsletter-style email               | Labeled `Triage/Newsletter`, stays in inbox                                 | [ ]   |
| 4   | Send ambiguous email from unknown sender    | Labeled `Triage/Review` + Telegram notification with Gmail link             | [ ]   |
| 5   | Tap "Approve" on a draft in Telegram        | Reply sent from Gmail, labeled `Triage/Approved`                            | [ ]   |
| 6   | Run `dispatcher.sh` twice quickly           | Second run skips (lockfile guard active)                                    | [ ]   |
| 7   | Check `pending-drafts.json` after approving | Entry for that email is deleted                                             | [ ]   |


**Trigger a manual run to test without waiting 15 minutes:**

```bash
openclaw cron run <job-id-from-cron-list>
```

**If a test fails — check run history:**

```bash
openclaw cron runs --id <job-id>
```

**Common failure causes:**

- "API not enabled" → enable Gmail API in GCP Console
- "Access blocked" → add yourself as test user in OAuth consent screen
- Label errors → check `data/label-ids.env` has correct IDs; Gmail API requires IDs not label names
- Auth errors → re-run `gws auth login -s gmail`; if in test mode, tokens expire after 7 days (see Known Gotchas below)

**Status when done:**

```
Phase 7: [x] Complete
Phase 8: [x] Complete — ALL TESTS PASSING
```

---

## Cron Job Management (Post-Setup Reference)

```bash
# View run history
openclaw cron runs --id <job-id>

# Manually trigger
openclaw cron run <job-id>

# Temporarily pause
openclaw cron edit <job-id> --disable

# Re-enable
openclaw cron edit <job-id> --enable
```

---

## If You Hit the Usage Limit Mid-Session

1. Ask Claude: *"Summarize where we are, what's done, what's next, and any gotchas"*
2. Save that summary here in **Current Status**
3. Wait for 5-hour window to reset (check: Settings → Usage in claude.ai)
4. Start a fresh conversation, paste the next Session Header

**Optional safety net:** Enable Extra Usage in Settings → Usage → set a $5–10 monthly cap.
This lets you continue at API rates if you hit the wall mid-troubleshoot.

---

## Known Gotchas

### gws OAuth Token Expiry (7-day limit in test mode)

GCP OAuth apps in **test mode** issue refresh tokens that expire after **7 days**. After 7 days, `gws` commands will return auth errors and the dispatcher will fail silently.

**Temporary fix** (weekly): `gws auth logout && gws auth login -s gmail`

**Permanent fix**: Publish the OAuth app. In GCP Console → APIs & Services → OAuth consent screen → click "Publish App". Once published, refresh tokens do not expire on a 7-day cycle. You will need to go through a verification process for sensitive scopes (Gmail modify/send), but for personal use with yourself as the only user, verification is not strictly required — Google will warn but not block.

### lobster as a shell binary

`lobster` (`@clawdbot/lobster`) is installed as a standalone npm binary at `/usr/local/opt/node@22/bin/lobster`. It can be called directly from shell scripts via `lobster run --file <workflow> --args-json '{...}'`. `dispatcher.sh` uses this to invoke the `email-triage.lobster` workflow for each email.

**Key gotchas**:
- Arg template syntax is `${email_id}` (not `$LOBSTER_ARG_EMAIL_ID` — that is not set by Lobster)
- Steps execute via `/bin/sh -lc`, which sources login profile files and can override `node` to v20. All scripts must start with `export PATH="/usr/local/opt/node@22/bin:$PATH"`.
- Env vars in the `env:` section of workflow YAML are NOT shell-expanded (`~` and `$HOME` do not expand). Use absolute paths.

### openclaw.invoke is not available from shell

`openclaw.invoke` is agent-internal only. It cannot be called from bash scripts running outside of an OpenClaw agent session. Attempting to call it from a cron-triggered bash script will fail.

Replacements actually used:
- LLM calls: `openclaw agent --agent email-triage --session-id "triage-$$" --json`
- Telegram messages: `openclaw message send --channel telegram --target "CHAT_ID"`

---

## Pipeline Diagram

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

## Files Reference

```
~/.openclaw/workspace/
├── scripts/
│   ├── dispatcher.sh          ← fetches email IDs; calls `lobster run` per email
│   ├── fetch-email.sh         ← extracts message_id (RFC 2822 Message-ID header)
│   ├── classify-email.sh      ← uses openclaw agent --agent email-triage (Haiku)
│   ├── draft-reply.sh         ← uses openclaw agent --agent email-triage (Haiku, not Sonnet)
│   ├── mark-processed.sh      ← sources label-ids.env, uses label IDs
│   ├── route-and-act.sh       ← sources label-ids.env, creates Gmail draft, uses RFC message_id
│   ├── send-approved-reply.sh ← uses drafts.send with gmail_draft_id
│   ├── setup-labels.sh        ← DO NOT USE (jq exit 5 bug); create labels manually instead
│   └── cleanup-stale-drafts.sh
├── workflows/
│   └── email-triage.lobster   ← Lobster workflow; called by dispatcher.sh per email
├── memory/
│   └── triage-rules.md        ← YOU customize this
├── data/
│   ├── pending-drafts.json    ← includes gmail_draft_id per entry
│   ├── label-ids.env
│   └── logs/
│       ├── dispatcher.log
│       └── cleanup.log
└── email-triage-implementation-plan.md   ← this file
```

---

*Generated 2026-03-14. Updated to reflect actual implementation. Based on email-triage-mvp-spec-v2.2 and EMAIL-TRIAGE-IMPLEMENTATION-README.md*
