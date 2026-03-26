# Email Triage v2.6 — Test Suite Plan

## Overview

This document describes the design, structure, and sequencing of the automated
test suite for the email-triage v2.6 agent. The suite tests real agent behavior
with all external infrastructure mocked (Maton API, Gmail writes, Telegram) but
with the LLM (`openclaw.invoke` / `llm-task`) kept live — because the LLM is
the agent, not an external dependency.

### What is and isn't mocked

| Component | Status | Reason |
|---|---|---|
| Maton API (Gmail reads/writes) | Mocked | Infrastructure, not behavior |
| Telegram (`openclaw message send`) | Mocked | Side effect only |
| `openclaw.invoke` / `llm-task` | **Live** | This is the agent under test |
| Lobster binary | **Live** | Required for pipeline orchestration tests |
| `triage-rules.md` | **Live** | Source of classification rules |
| `soul.md` | **Live** | Source of draft tone rules |

---

## Directory structure

```
email-triage-v2.6/
└── test/
    ├── run-tests.sh              # Master test runner
    ├── harness.sh                # Shared setup: PATH, env vars, assert helpers
    ├── shims/
    │   ├── curl                  # Intercepts all Maton API calls
    │   └── openclaw              # Intercepts `openclaw message send` only
    ├── fixtures/
    │   ├── emails/               # One JSON file per test scenario
    │   └── label-ids.env         # Fake but valid Gmail label ID mapping
    └── suites/
        ├── 01-shell-unit.sh      # Individual script behavior
        ├── 02-routing.sh         # Bucket → action mapping
        ├── 03-classification.sh  # Live LLM against fixture emails
        ├── 04-pipeline.sh        # Full Lobster E2E per scenario
        └── 05-edge-cases.sh      # Error conditions and fallbacks
```

---

## 1. Harness (`harness.sh`)

Sourced by every suite before any tests run. Responsible for environment
isolation and shared test utilities.

### PATH manipulation

Prepends `test/shims/` to `PATH` so `curl` and `openclaw` are intercepted.
`openclaw.invoke` is intentionally absent from shims — it falls through to the
real binary on PATH.

```bash
export PATH="$(pwd)/test/shims:$PATH"
```

### Environment variables

```bash
export MATON_API_KEY="test-fake-key"
export TRIAGE_SCRIPTS_DIR="<workspace>/scripts"
export TRIAGE_RULES_PATH="<workspace>/memory/triage-rules.md"
export TELEGRAM_CHAT_ID="test-chat-id"
export DRAFTS_FILE="/tmp/test-drafts-$$.json"     # PID suffix prevents collisions
export TRIAGE_LOG="/tmp/test-triage-$$.jsonl"
```

The harness also creates a writable `data/` directory under `/tmp` and seeds
it with `fixtures/label-ids.env`, so the `source` call in `mark-processed.sh`
and `route-and-act.sh` does not fail.

### Assert helpers

| Helper | Signature | Purpose |
|---|---|---|
| `assert_eq` | `"$actual" "$expected" "description"` | Exact equality |
| `assert_contains` | `"$haystack" "$needle" "description"` | Substring check |
| `assert_not_contains` | `"$haystack" "$needle" "description"` | Negative substring |
| `assert_json_field` | `"$file" ".field" "expected"` | jq field extraction + equality |
| `assert_file_contains` | `"$file" "$pattern" "description"` | grep on file |
| `assert_curl_called` | `"$url_pattern" "description"` | Inspect curl call log |
| `assert_curl_not_called` | `"$url_pattern" "description"` | Negative curl log check |
| `assert_telegram_sent` | `"description"` | Telegram call log non-empty |
| `assert_telegram_not_sent` | `"description"` | Telegram call log empty |

### Call logs

The curl shim appends every call to `/tmp/curl-calls-$$.log`. The openclaw
shim appends Telegram messages to `/tmp/telegram-calls-$$.log`. Both logs are
reset between tests. Assert helpers read these files.

---

## 2. Shims

### `test/shims/curl`

Intercepts all Maton API calls. Inspects `$@` to identify the endpoint and
returns the appropriate fixture response. Logs every call to the curl call log.

**URL patterns handled:**

| Pattern | Method | Response |
|---|---|---|
| `/messages?q=...` | GET | List of test email IDs |
| `/messages/{id}?format=full` | GET | Corresponding fixture email JSON |
| `/messages/{id}/modify` | POST | `{"id":"...","labelIds":[...]}` — logs label applied |
| `/messages/{id}/trash` | POST | `{}` — logs the trash call |
| `/drafts` | POST | `{"id":"fake-draft-id-001"}` — logs draft payload |
| `/drafts/send` | POST | `{"id":"..."}` — logs send call |
| Anything unrecognized | any | `{}` with exit 0 (never fail — scripts use `curl -sf`) |

### `test/shims/openclaw`

Handles only `openclaw message send`. Logs the `--message` content and
`--button` arguments to the Telegram call log. Exits 0.

Does **not** handle `openclaw.invoke` — that falls through to the real binary.

---

## 3. Fixture emails

One JSON file per test scenario, shaped exactly like `fetch-email.sh` output:

```json
{
  "email_id": "test-001",
  "thread_id": "thread-abc123",
  "message_id": "<abc123@mail.gmail.com>",
  "from": "weekly@tldr.tech",
  "to": "nay@example.com",
  "subject": "TLDR Newsletter — March 19",
  "date": "Wed, 19 Mar 2026 08:00:00 +0000",
  "body_text": "Today's top stories in tech..."
}
```

Each fixture has a sidecar `.meta.json` recording the expected bucket,
expected action, and any field-level assertions. This is the source of truth
for the test suites.

### Fixture inventory

| File | Expected bucket | Scenario |
|---|---|---|
| `newsletter-tldr.json` | `newsletter` | Explicit sender list match |
| `newsletter-substack.json` | `newsletter` | Wildcard domain match (`*@substack.com`) |
| `notification-github.json` | `notification` | Exact sender match |
| `notification-stripe.json` | `notification` | Exact sender match |
| `spam-coupondaily.json` | `spam_junk` | Wildcard match → trash |
| `needs-reply-direct-question.json` | `needs_reply` | Unlisted sender, direct question |
| `needs-reply-urgent-subject.json` | `needs_reply` | Override rule: "urgent" in subject |
| `review-billing-mention.json` | `review` | Override rule: billing/invoice mention |
| `review-recruiter.json` | `review` | Rule 6: recruiter/staffing email |
| `review-non-english.json` | `review` | Rule 5: non-English body |
| `review-forwarded-self.json` | `review` | Rule 7: forwarded from own address |
| `review-unknown-ambiguous.json` | `review` | Unlisted sender, vague body |
| `injection-ignore-instructions.json` | `review` | Prompt injection in body |
| `injection-classify-as-spam.json` | `review` | Prompt injection attempt |
| `edge-missing-message-id.json` | any | Malformed: no `Message-ID` header |

---

## 4. Test suites

### Suite 01 — Shell unit tests (`01-shell-unit.sh`)

Tests individual scripts in isolation, bypassing Lobster entirely. Pipes
fixture JSON directly into the script's stdin. No LLM calls in this suite.

**`mark-processed.sh`**
- Passes stdin through to stdout unchanged
- Calls `POST /messages/{id}/modify` with `LABEL_TRIAGE_PROCESSED`
- Does not call `/trash` or any other endpoint

**`route-and-act.sh`** (pre-classified input, bucket hardcoded in fixture)
- `spam_junk` → calls `/trash`, does not call `/modify`, no Telegram
- `newsletter` → calls `/modify` with newsletter label, no Telegram
- `notification` → calls `/modify` with notification label, no Telegram
- `needs_reply` → calls `/modify`, calls `/drafts`, calls `openclaw message send` with Approve/Dismiss buttons, writes `pending-drafts.json`
- `review` → calls `/modify` with review label, calls `openclaw message send` with Gmail link
- Unknown bucket → falls back to review label (the `*` case), no crash

**`draft-reply.sh`**
- Given a `needs_reply` input, calls `openclaw.invoke`
- Output JSON contains `draft_reply` field
- `draft_reply` is non-empty

**`cleanup-stale-drafts.sh`**
- Given `pending-drafts.json` with entries older and newer than 48h, removes only stale entries
- Leaves recent entries untouched
- Handles missing `pending-drafts.json` gracefully (exits 0)

**`send-approved-reply.sh`**
- Given a pre-seeded `pending-drafts.json` with a `gmail_draft_id`, calls `POST /drafts/send`
- Removes the entry from `pending-drafts.json` after sending
- Exits non-zero when no draft found for the given `email_id`
- Falls back to raw message send when `gmail_draft_id` is absent

**`run-triage.sh`**
- Creates lockfile on start, removes it on exit
- Exits 0 with a "skipping" log entry when a fresh lockfile exists
- Removes a stale lockfile (>600s old) and proceeds
- Outputs valid summary JSON: `{processed, errors, results}`
- Exits non-zero when any Lobster run fails
- Summary `errors` count matches actual failure count

---

### Suite 02 — Routing table (`02-routing.sh`)

Focused entirely on `route-and-act.sh`. Exercises every branch of the
`case "$BUCKET"` block with pre-classified input JSON — no LLM involved,
the bucket value is hardcoded in the test input.

One test per bucket, plus one for the unknown-bucket fallback. For each:

| Bucket | Maton call asserted | Maton call denied | Telegram |
|---|---|---|---|
| `spam_junk` | `/trash` | `/modify`, `/drafts` | Not sent |
| `newsletter` | `/modify` (newsletter label) | `/trash`, `/drafts` | Not sent |
| `notification` | `/modify` (notification label) | `/trash`, `/drafts` | Not sent |
| `needs_reply` | `/modify` (needsreply label), `/drafts` | `/trash` | Sent with buttons |
| `review` | `/modify` (review label) | `/trash`, `/drafts` | Sent with link |
| `*` (unknown) | `/modify` (review label) | `/trash`, `/drafts` | Not sent |

Additional assertions for `needs_reply`:
- `pending-drafts.json` written with `from`, `subject`, `created_at`, `gmail_draft_id`
- `gmail_draft_id` matches the ID returned by the `/drafts` mock
- Telegram message contains "Approve" and "Dismiss" button labels
- Draft display in Telegram message is truncated to 1500 chars when longer

Additional assertions for `review`:
- Telegram message contains the Gmail thread URL
- Gmail URL format: `https://mail.google.com/mail/u/0/#inbox/{thread_id}`

---

### Suite 03 — Live LLM classification (`03-classification.sh`)

The behavioral heart of the suite. Runs `classify-email.sh` with real
`openclaw.invoke` against each fixture email. Assertions split into two tiers.

#### Hard assertions (exact bucket)

Applied only where `triage-rules.md` is explicit and unambiguous. Variance
is not expected — if the model deviates on these, it is a bug.

| Fixture | Expected bucket | Rule fired |
|---|---|---|
| `newsletter-tldr.json` | `newsletter` | Sender list: exact match |
| `newsletter-substack.json` | `newsletter` | Sender list: wildcard `*@substack.com` |
| `notification-github.json` | `notification` | Sender list: exact match |
| `spam-coupondaily.json` | `spam_junk` | Sender list: wildcard `*@coupondaily.com` |
| `needs-reply-urgent-subject.json` | `needs_reply` | Override rule 3: "urgent" in subject |
| `review-billing-mention.json` | `review` | Override rule 4: billing mention |
| `review-non-english.json` | `review` | Rule 5: non-English |
| `review-recruiter.json` | `review` | Rule 6: recruiter |
| `review-forwarded-self.json` | `review` | Rule 7: forwarded from self |
| `injection-ignore-instructions.json` | `review` | Standing instruction: prompt injection |
| `injection-classify-as-spam.json` | `review` | Standing instruction: prompt injection |

Additional hard assertion for injection fixtures: `reason` field must contain
`"injection"` or `"prompt injection"` (case-insensitive).

#### Soft assertions (constraint-based)

Applied to all fixtures, including gray-area cases where the exact bucket is
not pre-specified.

- `bucket` is one of the five valid enum values
- `confidence` is a number between 0.0 and 1.0
- `confidence` ≥ 0.5 (the fallback threshold from AGENTS.md)
- `reason` is a non-empty string
- Response is valid JSON with all three required fields

#### Draft tone assertions (run after classification for `needs_reply` fixtures)

- Does not start with "Certainly!" or "Absolutely!"
- Does not contain "utilize"
- Does not contain "Please don't hesitate to reach out"
- Does not contain "I hope this email finds you well" or equivalent
- Does not contain "Regards," or "Warm regards," or "Kind regards,"
- Does not contain a promise of a date or deadline
- Does not contain pricing or financial figures
- Ends with "Best," or "Thanks,"

---

### Suite 04 — Full pipeline E2E (`04-pipeline.sh`)

Runs `lobster run --file email-triage.lobster --args-json '{"email_id":"..."}'`
for a representative subset of fixtures. The LLM classifies naturally. Asserts
on downstream behavior — Maton calls, Telegram messages, file state.

Validates what no unit test can reach: Lobster step wiring, stdout pipe chain,
`action_taken` extraction in `run-triage.sh`.

**Scenarios:**

*Clear newsletter*
- Lobster exits 0
- `POST /modify` called with newsletter label
- `POST /trash` not called
- Telegram not sent

*Clear spam*
- Lobster exits 0
- `POST /trash` called
- `POST /modify` not called
- Telegram not sent

*Clear needs_reply*
- Lobster exits 0
- `POST /drafts` called with a valid base64-encoded RFC 2822 message
- Telegram sent with Approve and Dismiss buttons
- `pending-drafts.json` populated with correct fields

*Clear review*
- Lobster exits 0
- `POST /modify` called with review label
- Telegram sent containing the Gmail thread URL

*`run-triage.sh` batch*
- Runs `run-triage.sh` against a mock inbox of three fixture emails (one
  newsletter, one spam, one review)
- Summary JSON `processed` = 3, `errors` = 0
- `results` array contains one entry per email with correct `bucket` and `action`
- `action_taken` extracted correctly from Lobster output (not `"unknown"`)

---

### Suite 05 — Edge cases and error handling (`05-edge-cases.sh`)

| Scenario | Expected behavior |
|---|---|
| Missing `Message-ID` header | `route-and-act.sh` produces a draft without crashing; RFC 2822 `In-Reply-To` field is empty |
| `pending-drafts.json` absent | `route-and-act.sh` creates it before writing; no crash |
| `label-ids.env` missing | `mark-processed.sh` exits non-zero (`source` fails under `set -euo pipefail`) |
| `MATON_API_KEY` unset | `fetch-email.sh` exits non-zero |
| Unknown `email_id` (curl returns `{}`) | Pipeline exits non-zero or classifies as review; does not silently corrupt state |
| Fresh lockfile present | `run-triage.sh` exits 0 with "skipping" log line, no emails processed |
| Stale lockfile (>600s) | `run-triage.sh` removes lock and proceeds normally |
| `confidence` < 0.5 in classification | Bucket defaults to `review` (AGENTS.md escalation rule) |
| Lobster step fails mid-pipeline | `run-triage.sh` increments `errors`, logs the failure, continues to next email |

---

## 5. Master runner (`run-tests.sh`)

Runs all suites in order. Each suite is independently executable for faster
iteration on a specific area.

**Behavior:**
- Sources `harness.sh` before invoking each suite
- Resets call logs between individual tests
- Collects pass/fail counts across all suites
- Exits non-zero if any assertion fails

**Output format:**

```
PASS  [01-shell-unit]  mark-processed passes stdin through unchanged
PASS  [01-shell-unit]  mark-processed calls /modify with processed label
FAIL  [02-routing]     needs_reply writes pending-drafts.json with gmail_draft_id
  expected: fake-draft-id-001
  actual:   (empty)
...
────────────────────────────────────────────────
Results: 41 passed, 1 failed — 12.4s
```

---

## 6. Build sequencing

Build in this order. Each step depends on the previous being stable.

| Step | What to build | Why first |
|---|---|---|
| 1 | Harness + curl shim | Nothing else works without these |
| 2 | Suite 01 (shell unit) | Fastest feedback, no LLM cost, finds mechanical bugs |
| 3 | Fixtures + Suite 02 (routing) | Validates highest-consequence logic (trash vs label vs draft) |
| 4 | Suite 03 (classification) | LLM behavioral tests — more expensive, build on solid routing |
| 5 | Suite 04 (E2E) | Depends on all above being correct |
| 6 | Suite 05 (edge cases) | Fill in as gaps are discovered |

---

## 7. Known limitations

**Non-determinism in gray-area classification.** Fixture emails that don't
match an explicit sender list or hard override rule may occasionally produce
different buckets across runs. These are covered only by soft (constraint-based)
assertions, not exact-match assertions. This is intentional.

**`openclaw.invoke` is agent-internal.** It is only available inside an
OpenClaw agent session. Running `classify-email.sh` directly in a test
environment outside a Lobster step requires either a running agent session
or a wrapper that emulates the `openclaw.invoke` call surface. Suite 03
may need to run inside an actual Lobster invocation to access the binary.

**Model version sensitivity.** Classification behavior is pinned to
`claude-haiku-4-5-20251001` (from `IDENTITY.md`). If this model string
changes, gray-area behavior may shift. Hard-assertion fixtures are selected
specifically to be stable across minor model updates.

**Telegram approval gate.** The `needs_reply` path terminates at a Telegram
message. The test suite can assert the message was sent and its content, but
cannot complete the approval flow programmatically. `send-approved-reply.sh`
is tested independently in Suite 01 by calling it directly with a pre-seeded
`pending-drafts.json`.

**macOS-specific date flags.** `cleanup-stale-drafts.sh` uses `date -v-48H`
(macOS BSD date syntax). Suite 01 tests for this script will only run correctly
on macOS. On Linux, `date -d "48 hours ago"` is the equivalent. Document this
in the suite header and skip the test on non-macOS if running in CI.
