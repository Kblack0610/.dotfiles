---
name: flow-review
description: Walk one user flow end to end (web at desktop and phone width, mobile app) and write it up as a markdown report with a screenshot per step and a severity on every note (FIX / POLISH / VERIFY / OK), saved to `~/.notes/ref/<project>/<date>-<slug>/` (synced to every device) with a PDF beside it, readable in the terminal with glow or yazi. Use when the user says "walk the payment flow and write it up", "do a flow review", "summary like the Julie one", "screenshot every step of X", "put it in my ref folder", "make a PDF of the review", or wants a readable walkthrough of one journey for a human. Can also convert an existing HTML walkthrough artifact into this format with `scripts/extract-artifact.py`. For a whole-app screen sweep with a coverage matrix use `ui-audit`; for audit-then-fix-and-merge use `delta-audit`; for a wave sign-off gate use `wave-closeout`. This skill reports; it does not fix.
metadata:
  category: authoring
  tags: [review, screenshots, markdown, walkthrough]
  reviewed: "2026-09-23"
---

# flow-review

Produces a step-by-step walkthrough of ONE user flow as a markdown file, real screenshot files and a PDF, in a folder under `~/.notes` that the notes sync carries to every device. The reader should be able to act on the tally line alone, then scroll for the evidence. The worked example is `references/example.md`; the full original is the 2026-09-23 Julie payment flow under `~/.notes/ref/` (find it with `ls ~/.notes/ref/*/`).

## When to Use

- The user wants one journey (pay, sign up, request care, onboard) walked and written up with screenshots.
- The user has an HTML walkthrough artifact and wants it as markdown in the ref folder.

Not for every screen in the app (`ui-audit`) or for fixing what you find (`delta-audit`, `bug-bash`).

## Output

```
~/.notes/ref/<project>/<YYYY-MM-DD>-<slug>/
  README.md
  report.pdf
  shots/NN-<step>-<viewport>.jpg
~/.notes/ref/<project>/INDEX.md     # one line per report, newest first
```

`<project>` is the app or product the flow belongs to, matching its notes-board name. `~/.notes` is a git repo that auto-syncs, so every screenshot stays in its history forever: capture JPEG at quality 80 (Playwright `type: "jpeg"`), which keeps a 20-shot report near 1MB, and do not re-capture an unchanged flow just to refresh it.

## Steps

1. **Scope.** Name the flow, its start and end state, the account/role, the surfaces (web, mobile app, native), viewports (default web 1280 and 390), and the env plus the commit it is serving. Confirm the env really serves that commit before capturing; a report against a stale build is worse than none.
2. **Create the folder** `~/.notes/ref/<project>/<date>-<slug>/shots/`.
3. **Walk it.** Web with Playwright MCP, Android with `adb-ops`. Save each screenshot straight into `shots/` with a zero-padded running number: `01-checkout-desktop.jpg`. Never embed base64 in the markdown; terminal viewers cannot show it. Drive the flow to its real end state (payment submitted, record written) and check that the state changed.
4. **Judge each step.** One line on what the user does and sees, then one bullet per note, prefixed with its severity in bold (`- **FIX** ...`):

   | Severity | Meaning |
   | --- | --- |
   | FIX | A defect a user would notice. Add `file:line` when you know it. |
   | POLISH | Works, but looks or reads wrong. |
   | VERIFY | Cannot be judged in this env; say where and what to check. |
   | OK | Checked and right. Keep these; they show what was covered. |

   Measure layout claims in the DOM (overflow, padding, clipping) before writing them; a screenshot eyeball read is not evidence.
5. **Write README.md** from `assets/template.md`: title, context line, one-paragraph lede (who, what, where, env, commit, date, whether anything real happened), meta bullets, tally line, one `##` per surface, one `###` per step, then "What this is not". Count the tally from the notes; do not estimate it.
6. **Prose pass.** Plain ASCII, no em dashes or arrows. Run the `de-ai-writing` skill's `scripts/check.py` on README.md.
7. **PDF.** Run `~/.claude/skills/flow-review/scripts/to-pdf.py <report-dir>`; it writes `report.pdf` beside README.md with screenshots stacked full width. Open a page or two to check nothing is cropped.
8. **Index.** Add a line to the top of `~/.notes/ref/<project>/INDEX.md`: `- [<date> <title>](<dir>/README.md) - <one-line scope>; <tally>`. Create the file with a `# <project> flow reviews` heading if missing.
9. **Hand off.** Give the user the path and the view commands below. Findings with prod user, PHI, security or money impact go on the project sheet per the usual rules; the rest stay in the report. If the user wants a shareable link, publish an HTML Artifact built from the README; the markdown stays the source.

## Converting an existing artifact

```bash
~/.claude/skills/flow-review/scripts/extract-artifact.py <artifact.html> ~/.notes/ref/<project>/<date>-<slug>
```

Get the HTML with the Artifact tool's `read` action; it saves the full page to a local file. The script expects the flow-review markup (h1, `.lede`, `.meta`, `.tally`, `h2` per surface, `article.step` with `li.sev-*` notes and `figure` images, `#caveats` footer). Then do steps 7 and 8. Check that every `shots/` link in the output resolves and the count matches the figures in the page.

## Viewing in the terminal

- `yazi ~/.notes/ref`: browse reports, preview README.md and the screenshots inline (kitty graphics, works in tmux because `allow-passthrough` is on).
- `glow ~/.notes/ref/<project>/<dir>/README.md`: rendered markdown. Images show as links; open them in yazi.
- `chafa shots/<file>`: one screenshot in any terminal without kitty graphics.
- `xdg-open <dir>/report.pdf`: the PDF, for sharing or reading away from the terminal.

## Do NOT

- Do not embed screenshots as base64 or link to temp paths; the report must survive the session and render in yazi.
- Do not write a report for an env you have not confirmed is serving the commit you name.
- Do not stop at "the screen rendered". A flow review that never completes the payment has not reviewed the flow.
- Do not drop OK notes to make the report shorter; without them a reader cannot tell a clean step from an unchecked one.
