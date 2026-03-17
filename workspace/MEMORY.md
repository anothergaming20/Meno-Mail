# MEMORY.md — Long-Term Memory

_Last updated: 2026-03-09_

---

## About Nay
- Location: Columbia, SC
- Timezone: Eastern
- Uses Claude OAuth (Pro subscription), not API key billing
- Prefers direct answers, not fluff

## Passphrases & Test Phrases

## Setup & Environment
- Running OpenClaw on macOS (Darwin 22.6.0, x64)
- No Docker installed — sandbox mode causes errors. Set `agents.defaults.sandbox.mode=off` to work around it.
- No browser (Chrome/Brave/Edge) detected on the machine — browser tool unavailable.
- QMD memory index exists but may need `qmd update && qmd embed` to stay current.

## Claude Usage (as of 2026-03-08)
- OAuth-based (subscription, not pay-per-token)
- Can check usage via rate-limit headers: 5-hour and 7-day windows
- On 2026-03-08: 11% of 5hr, 3% of 7-day used

## Lessons Learned
- **Search laterally.** "Pink element" ≠ exact match for "pink elephant" but should've been caught. Think fuzzy.
- **Read daily memory files** before saying "I don't know." The answer was sitting in `memory/2026-03-06.md`.
- **Don't just rely on QMD/memory_search** — also grep raw files when semantic search misses.
- **QMD collection name is `memory`, NOT `openclaw-memory`.** Fixed in AGENTS.md on 2026-03-09. Was silently failing every time.

---

_Update this file as significant things happen. Keep it concise._
