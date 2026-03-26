# Email Triage — v2.6 Deployment Guide

## What changed from v2.5

### The core architectural fix

v2.5 used `cron.jobs[].command` — a field that does not exist in OpenClaw's
cron schema. The scheduler ignored it, so the dispatcher was never triggered
by OpenClaw. v2.6 uses the correct `agentTurn` payload with `sessionTarget:
"isolated"`, which is what OpenClaw actually supports.

### What this gives you

Every cron run now produces:
- A full session transcript: `~/.openclaw/agents/email-triage/sessions/<id>.jsonl`
- A run log entry: `~/.openclaw/cron/runs/email-triage-dispatcher.jsonl`
- All tool calls, llm-task calls, exec calls, and their results — logged automatically

Query with:
```bash
openclaw cron runs --id email-triage-dispatcher --limit 20
openclaw sessions --agent email-triage
```

### Changed files

| File | Change |
|---|---|
| `config/openclaw-config-snippet.json5` | Cron jobs use `agentTurn` payload; skills.entries.gmail wires MATON_API_KEY; `exec` added to alsoAllow |
| `AGENTS.md` | Added exec-tool cron execution pattern and error reporting instructions |
| `scripts/run-triage.sh` | New file — replaces dispatcher.sh; called by agent via exec tool; outputs structured JSON log lines |
| `scripts/classify-email.sh` | `openclaw agent` → `openclaw.invoke --tool llm-task` |
| `scripts/draft-reply.sh` | `openclaw agent` → `openclaw.invoke --tool llm-task` |
| `workflows/email-triage.lobster` | Updated comments; removed MATON_API_KEY env workaround (now from skill env) |

### Removed files

| File | Reason |
|---|---|
| `scripts/dispatcher.sh` | Replaced by `run-triage.sh` + agent cron agentTurn pattern |

---

## Installation steps

### 1. Copy all files to workspace

```bash
WORKSPACE=~/.openclaw/workspace

# Identity files
cp AGENTS.md soul.md user.md "$WORKSPACE/"

# Memory
cp memory/triage-rules.md "$WORKSPACE/memory/"

# Scripts (make executable)
cp scripts/*.sh "$WORKSPACE/scripts/"
chmod +x "$WORKSPACE/scripts/"*.sh

# Workflow
cp workflows/email-triage.lobster "$WORKSPACE/workflows/"
```

### 2. Remove old dispatcher.sh

```bash
rm -f ~/.openclaw/workspace/scripts/dispatcher.sh
```

### 3. Add MATON_API_KEY to environment

```bash
# Add to ~/.zprofile so OpenClaw picks it up on startup
echo 'export MATON_API_KEY="your-key-here"' >> ~/.zprofile

# Also add to ~/.openclaw/.env for Gateway process
echo 'MATON_API_KEY=your-key-here' >> ~/.openclaw/.env
```

### 4. Register the email-triage agent

```bash
openclaw agents add email-triage \
  --model "anthropic/claude-haiku-4-5-20251001" \
  --workspace "$HOME/.openclaw/workspace" \
  --non-interactive
```

### 5. Install Gmail skill

```bash
mkdir -p ~/.openclaw/workspace/skills/gmail
curl -s https://raw.githubusercontent.com/openclaw/skills/main/skills/byungkyu/gmail/SKILL.md \
  > ~/.openclaw/workspace/skills/gmail/SKILL.md
```

### 6. Merge openclaw-config-snippet.json5 into openclaw.json

Key sections to add/update:
- `agents.list` — email-triage agent definition
- `plugins.entries.llm-task` — enable llm-task plugin
- `tools.alsoAllow` — add `"exec"` alongside `"lobster"` and `"llm-task"`
- `skills.entries.gmail` — MATON_API_KEY injection
- `cron.jobs` — two agentTurn jobs (replace the old command-based jobs)

### 7. Smoke test

```bash
# Verify cron jobs registered correctly
openclaw cron list

# Manual test run (force, no need to wait for schedule)
openclaw cron run email-triage-dispatcher

# Check the run log
openclaw cron runs --id email-triage-dispatcher --limit 5

# Check session transcript
openclaw sessions --agent email-triage
```

---

## Architecture (v2.6)

```
OpenClaw cron (every 15 min)
  └─ agentTurn: email-triage agent (isolated session)
       │  Session transcript: ~/.openclaw/agents/email-triage/sessions/<id>.jsonl
       │  Run log: ~/.openclaw/cron/runs/email-triage-dispatcher.jsonl
       │
       └─ agent calls exec tool:
            bash run-triage.sh
              ├─ curl Maton → fetch email IDs
              └─ for each ID: lobster run email-triage.lobster
                   ├─ fetch-email.sh    (curl Maton)
                   ├─ classify-email.sh (openclaw.invoke --tool llm-task)
                   ├─ mark-processed.sh (curl Maton)
                   └─ route-and-act.sh
                        ├─ curl Maton (label/trash/draft)
                        ├─ draft-reply.sh (openclaw.invoke --tool llm-task)
                        └─ openclaw message send (Telegram)

OpenClaw cron (daily 3am)
  └─ agentTurn: email-triage agent (isolated session, lightContext)
       └─ agent calls exec tool:
            bash cleanup-stale-drafts.sh

## Why openclaw.invoke works here

classify-email.sh and draft-reply.sh call `openclaw.invoke --tool llm-task`.
This is an agent-internal function — it works because the scripts run inside
a Lobster step, which runs inside run-triage.sh, which is called by the agent's
exec tool during its agentTurn session. The full call chain is inside the
agent context, so openclaw.invoke is available.

In v2.4/v2.5, the scripts were called from a cron command (not an agent session),
so openclaw.invoke was unavailable and `openclaw agent` CLI was used as a
workaround. That workaround is no longer needed.
```

## Logging reference

```bash
# See last N cron runs and their status
openclaw cron runs --id email-triage-dispatcher --limit 20

# See all email-triage agent sessions (includes cron runs)
openclaw sessions --agent email-triage

# Tail the structured triage log file
tail -f ~/.openclaw/workspace/data/logs/triage.jsonl | jq .

# View Gateway logs (all subsystems)
openclaw logs --follow
```
