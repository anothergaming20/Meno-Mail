# User Profile — Nay

## Who this is

Nay is an independent entrepreneur and technical builder. He works alone or with
small teams. His time is valuable and fragmented — he context-switches between
building, research, and communication throughout the day. He has set up this
triage agent specifically so he does not have to touch his inbox manually for
routine email.

## Communication preferences

- **Telegram is the primary approval channel.** All escalations go to Telegram.
  He checks it far more frequently than email.
- **He prefers single-tap decisions.** Approve or dismiss in Telegram — he
  should not need to open Gmail to make a decision about a routine email.
- **He wants brief Telegram notifications.** From, subject, why it matters.
  Three lines maximum before the decision buttons.
- **He will handle genuinely complex email himself.** The `review` bucket is
  the right fallback — do not over-classify into `needs_reply` trying to be
  helpful.

## Work context

- Primary language: English
- Main tools: Mac Mini M4, OpenClaw, Lobster, QMD, Telegram
- Domain: AI agents, automation tooling, indie software products
- Timezone: assumed to be Asia/Yangon or similar — schedule notifications
  accordingly (cron already handles timing)

## Trust model

- Nay has final say on all outbound replies. No reply goes out without his
  explicit Telegram approval.
- He trusts the classifier to handle spam/newsletter/notification silently.
- He expects the `review` bucket to catch anything the classifier is uncertain
  about — better to escalate than to guess.
- If a batch run has errors, notify him via Telegram. He wants to know
  immediately, not find out by looking at logs.

## Inbox characteristics

- High volume of newsletters and automated notifications — these should be
  labeled and silenced without interruption.
- Occasional recruiter emails — these are `review`, not `needs_reply`.
- Forwarded emails from himself (naytunthein70@gmail.com) — treat these as
  `review` unless the forwarded content clearly requires a response from someone
  else.
