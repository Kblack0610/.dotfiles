# Real board shapes

Sanitized copies of every distinct board shape found under `~/.agent/plans/*/sprint-*.md`.

**Why these are not invented.** The suite's original board fixtures were all headed
`| # | Ticket | Title | Status |` — a shape **no real board has ever used**. They were
written from the parser rather than from the corpus, so a parser bug that returned zero
rows on every real board survived 19 green tests. Fixtures derived from the
implementation agree with the implementation, including where it is wrong.

Structure and status vocabulary are verbatim; ticket titles and any person's name are
replaced. The status cells matter most and are kept exactly: they are prose a human or
an agent wrote (`**DONE — PR #1036 merged**`, `filed, not dispatched`, `dispatched`,
`MERGED (PR #1004, CI green)`), not a controlled enum, and that is precisely what the
five pre-#170 parsers could not read.

`make -C tests corpus-check` re-derives the shapes on disk and reports any this
directory does not cover. It is advisory: it reads live state, so it cannot gate CI.

Project names are redacted here too: this repo is public, and the board paths name real
work. `make -C tests corpus-check` prints the live paths on the machine that has them.

| fixture | written by | what makes it its own case |
|---|---|---|
| `queue-ticket-first.md` | `/kb:sprint` | No `#` column — the shape `wave-session`'s parser read as ZERO rows |
| `wave-numbered.md` | a wave | Has `#` but **no Title column**, so the parser falls back to the first non-structural cell |
| `wave-gated.md` | a wave, pre-approval | Every Ticket cell is EMPTY (the stub written before the gate) and a second `## Wave gate` table follows the queue |
