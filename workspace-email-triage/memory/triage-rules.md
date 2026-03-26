# Triage Rules
# This file is the authoritative sender classification and reply style guide for MenoMail.
#
# AUTHORSHIP:
#   - Sections "VIP", "Spam/Junk", "Auto-Archive", "Notifications", "Newsletters" below
#     are seeded manually with your most important senders. Replace placeholders with
#     your real contacts before going live.
#   - After each labeling session in the Learn Mini App, apply-rule-diff.sh appends
#     new entries to the correct sections automatically. Do NOT overwrite this file
#     on subsequent runs — only append.
#
# PRIORITY: These rules override LLM classification. If a sender is listed here,
# the pre-triage lookup skips the LLM entirely.

---

## VIP (needs_reply — always draft a reply)
# Replace these placeholders with your most important contacts.
# Format: "Email Address" — optional note
# Examples:
# - "boss@company.com" — Direct manager, always reply same day
# - "client@importantclient.com" — Key client, formal tone
# - "partner@partnerco.com" — Business partner
#
# PLACEHOLDER — add your VIPs here:
"naytunthein70@gmail.com" - Human user
"caleb@gmail.com" - Business partner, friend
"tinaunglay@xy-trading.com" - Business partner, friend
"*@xy-trading.com" - Business clients

---

## Spam/Junk (auto-trash immediately, no notification)
# Senders that should always be trashed without reading.
# Also trash: unsolicited lottery/prize emails, phishing attempts, marketing with no unsubscribe.
#
# Content signals: emails claiming lottery wins, prize money, "claim your reward",
# requests for bank details from unknown senders → spam_junk
#
# PLACEHOLDER — add known spam senders here:
# - "spam@spammer.com" — Known spam
# - "lottery-prize.com" — Lottery scam domain

## Known spam domains (any email from these → spam_junk):
- domain "lottery-prize.com" → spam_junk
- domain "prize-winner.net" → spam_junk

---

## Auto-Archive (archive without reading, no notification)
# Senders whose emails you never need to read. They get labeled Triage/Notification
# and removed from inbox silently.
# Examples: automated reports, low-priority digests you subscribed to but never read.
#
# PLACEHOLDER — add auto-archive senders here:
# - "noreply@lowpriority.com" — Auto-archive this sender
# - "updates@someservice.com" — Never needs attention

---

## Notifications (scan — Triage/Notification label, archived from inbox)
# Emails that contain useful info but never need a reply.
# Examples: bank alerts, shipping notifications, calendar invites, build notifications.
#
# PLACEHOLDER — add notification senders here:
# - "alerts@mybank.com" — Banking alerts, scan for unusual charges
# - "no-reply@shipping.com" — Shipping notifications
# - "noreply@github.com" — GitHub notifications (unless @mentions)

---

## Newsletters (deep_read — Triage/Newsletter label, extract articles)
# Newsletters you actually read and want article extraction for.
# These go through the newsletter-extract agent for knowledge memory.
#
# PLACEHOLDER — add newsletter senders here:
# - "newsletter@tldr.tech" — TLDR Tech newsletter
# - "digest@morningbrew.com" — Morning Brew
# - "weekly@sometech.news" — A newsletter you enjoy

"*.medium.com" - Medium


---

## Reply Style Guide
# This section is loaded verbatim into the draft-reply agent's system prompt.
# Write this in first person as if you are describing your own email style.
# The agent will follow these rules exactly when drafting replies.
#
# PLACEHOLDER — customize this to match your actual communication style:

My reply style:
- Tone: Conversational and direct. Not overly formal unless the sender is formal first.
- Length: Brief. One to three sentences for simple replies. Longer only when genuinely needed.
- Sign-off: Just my first name. No "Best regards" or "Sincerely".
- Response time expectation: Same day for VIPs, within 24 hours for others.
- I never use jargon or buzzwords.
- I do not make financial commitments, legal agreements, or schedule meetings without
  explicit confirmation — draft should flag these for my review.
- If I am asked something I do not know the answer to, say "I'll check and get back to you."
- Do not start replies with "Hope this email finds you well" or similar filler.

---
# END OF TRIAGE RULES
# Next section: populated automatically by apply-rule-diff.sh after labeling sessions.
