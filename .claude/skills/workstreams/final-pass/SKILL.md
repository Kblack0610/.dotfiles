---
name: final-pass
description: >-
  The last cleanup on a finished diff before the merge gate runs: the built-in /simplify for reuse and simplification, then the house checks only this fleet knows (an existing helper one file over, one source of truth, content in config, no sleep-and-hope, shell quoting), then code-hygiene clean. Guards anything the project's lessons call load-bearing and skips diffs too small to be worth it. Use when the user says "final pass", "clean this up before the PR", "tidy the diff", "simplify this our way", or as one-shot step 3a. Diff-scoped and behavior-preserving. Defects are /code-review's job, a whole-repo audit is stack-review, and comments and residue alone are code-hygiene, which this skill runs as its last step.
metadata:
  category: workstreams
  tags: [review, hygiene, simplify]
  reviewed: "2026-10-28"
---

# final-pass

A finished diff usually carries a helper that already exists one file over, a fallback that hides the real fault, a magic number that belongs in config, and the comment noise `code-hygiene` exists for. The built-in `/simplify` catches the generic half and knows nothing about this fleet's rules or its lessons, including the ones that say a weird-looking thing is load-bearing. This skill runs the built-in, adds the house checks, and protects what the lessons protect. It produces a cleaner diff plus a short report, and it must run BEFORE the merge gate so the gate validates every edit it made.

## When to Use

- At the end of implementation, before the merge gate (one-shot step 3a).
- When the user asks for a final pass or a cleanup of the current change.

Not for finding defects - that is `/code-review`. Not for a repo-wide sweep - that is `stack-review`.

## Steps

1. **Scope.** BASE is the given commit, else the repo's default branch (`origin/main`; Gigantic repos use `origin/develop`, check the repo CLAUDE.md). Fetch first.
   ```bash
   MB=$(git merge-base HEAD "$BASE")
   git diff --name-only "$MB"...HEAD; git status --porcelain -z   # -z: renames and spaces stay intact
   git diff --shortstat "$MB"
   ```
   Edits stay in these files. A pre-existing copy of a pattern outside the diff's hunks goes in the report and stays as it is. Stop and say "skipped: <reason>" when the diff is under about 20 changed lines or touches only docs.

2. **Load-bearing guard.** Before editing anything, find what must not be simplified:
   ```bash
   . ~/.config/shared-hooks/project-name.sh
   TOP=$(git rev-parse --show-toplevel); P=$(resolve_project_name "$TOP")
   for f in <scoped files>; do
     k=$(basename "$f")
     case $k in SKILL.md|README.md|index.*|main.*|mod.rs|__init__.py) k=$(basename "$(dirname "$f")");; esac
     rg -n -C3 -F -e "$f" -e "$k" ~/.agent/lessons/$P.md "$TOP"/CLAUDE.md "$TOP"/AGENTS.md ~/.claude/CLAUDE.md
   done
   rg -n -i 'load-bearing|do not simplify|on purpose|deliberately' <scoped files>
   ```
   A missing CLAUDE.md or AGENTS.md shows as an rg error; that is fine, but do not hide it with `2>/dev/null`, or a typo in a path turns the guard off silently. Read each lessons hit's whole paragraph: the relevant rule is often headed "Rule:" and uses none of the keywords. Anything a lesson or comment calls deliberate is off limits for this pass; list it under "skipped as load-bearing".

3. **Baseline, then built-in `/simplify`.** Run the gate from step 7 once now, so a later red can be blamed on this pass or not. Then invoke `/simplify` with the step-1 range and file list and the step-2 do-not-touch list as its argument; left alone it picks its own range (`@{upstream}...HEAD`), which is wrong in a detached worktree. Re-read what it changed and revert any hunk that touches a step-2 item or changes behavior.

4. **House checks.** For each, the rule lives where the pointer says; apply it, do not restate it.
   - **Adjacent fix.** For every new function or helper, grep the sibling files and the repo for an existing one (`rg -n '<verb>_<noun>|<noun>'`). Use the existing one; if someone declined to reuse it on purpose, leave it. (memory `reference_adjacent_fix_pattern`)
   - **One source of truth.** A second copy of a config value, a shim around a broken layer, or a fallback that quietly papers over a fault: fold it into the canonical place, or list it if the canonical fix is out of scope. (CLAUDE.md, Core Principles)
   - **Content is data.** Text, numbers, tuning or rosters hardcoded where the system already reads a config: move them there. (CLAUDE.md, Standards)
   - **No sleep-and-hope.** A fixed delay or timer poll standing in for an event, promise or signal, in code or tests. (CLAUDE.md, Core Principles)
   - **Shell.** Any path or arbitrary value interpolated into a command string goes through `printf %q` (lessons `dotfiles.md`, printf %q rule). A pipeline's exit status is its last command's, so `! cmd | grep -q` passes when `cmd` dies (memory `reference_self_watch_blindspot`).
   - **Two live patterns for one job.** If the diff adds a second way to do something, pick one; when the old uses are out of scope, file one row on the project's agent board listing them (`notes ptask <lane> --agent add`). The board lane can differ from the lessons name: dotfiles work goes on `agent-runtime` or `notes-cockpit`. (CLAUDE.md, Standards)

5. **`code-hygiene clean`** on the same scope. It owns comments, debug residue, dead code and ASCII; do not repeat those checks here.

6. **Commit by concern.** Simplification and house-check fixes are separate `refactor:` commits; hygiene commits split the way code-hygiene step 5 splits them. Skip any concern with nothing in it.

7. **Gate.** Run the repo's merge gate as its CLAUDE.md defines it (one-shot step 4). For dotfiles that is the shell-test-harness gate: `make -C tests test-fast` on the host, and the ui tier only through `tests/docker.sh`, never on the host. If the gate goes red and the step-3 baseline was green, revert the hunk that broke it before trying anything else.

8. **Report.**
   ```
   final-pass: <N files>, <+a/-b> lines from <base>
   | File:line | Check | Action |
   |---|---|---|
   | lib/x.sh:40 | adjacent fix | reused fmt_age from lib/rows.sh |
   | lib/x.sh:12 | load-bearing (lessons dotfiles.md) | skipped |
   Left for a human: <item, why>
   ```

## Do NOT

- Run after the gate. Edits made after validation ship untested.
- Touch a file outside the step-1 list, or a pre-existing pattern outside the diff's hunks. Note it in the report instead.
- Simplify a construct a lesson or comment calls deliberate. Lessons record two cases where "simplifying" would have broken things: a hostile-looking test fixture that pinned a real bug, and networking in a playground that exists to exercise it.
- Count this as review. It does not look for bugs; `/code-review` does.
- Run it on a one-line fix or a docs change. The pass costs more than it can find there.
