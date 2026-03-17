# Email Triage Rules

## Sender Lists

### VIP (always needs_reply)
- (add your boss, key clients, partners here)

### Spam/Junk (auto-trash)
- *@coupondaily.com
- *@promo-*.com
- *@marketing-blast.com
- *@deals.*.com
- noreply@survey*.com

### Newsletters (label only)
- newsletter@morningbrew.com
- weekly@tldr.tech
- *@substack.com
- digest@medium.com
- *@mail.beehiiv.com
- hello@dense-discovery.com
- *@medium.com
- *@mail.cursor.com

### Notifications (label only)
- notifications@github.com
- no-reply@stripe.com
- no-reply@vercel.com
- no-reply@aws.amazon.com
- noreply@google.com
- no-reply@accounts.google.com
- shipment-tracking@amazon.com
- no-reply@sentry.io
- builds@circleci.com
- no-reply@netlify.com
- no-reply@digitalocean.com

## Classification Rules

1. Check sender lists first. If sender matches a list, classify accordingly.
2. If sender is unknown:
   - Marketing language + unsubscribe link → newsletter
   - Automated sender (no-reply, noreply, system@, mailer-daemon@) → notification
   - Direct question or request addressed to me → needs_reply
   - Default → review
3. If subject contains "urgent", "asap", or "time sensitive" → always needs_reply regardless of sender.
4. If email mentions money, invoices, payments, or billing → always review.
5. Emails in languages other than English → review.

## Reply Style

- Professional but not stiff. First-name basis with everyone.
- Short paragraphs. No fluff. Get to the point.
- Match the formality level of the sender — if they're casual, be casual back.
- Sign off with "Best," or "Thanks," depending on context.
- Never promise specific dates, deliverables, or commitments without my approval.
- Never share pricing, contracts, financial details, or internal information.
- If unsure how to respond, keep it brief and acknowledge receipt: "Thanks for this — I'll take a look and get back to you."
- Do not use exclamation marks excessively. One per email maximum.

## Standing Instructions

- Never auto-trash anything from a sender I've replied to in the past.
- If an email looks like a phishing attempt or social engineering, classify as review and note it in the reason.
- Calendar invitations → notification.
- Anything with an attachment from an unknown sender → review.
