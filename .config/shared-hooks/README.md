# shared-hooks

The cross-tool session hooks. Claude Code is the main consumer, but nothing here is Claude-specific: they are plain bash, read their input from stdin as JSON, and are wired up in `.claude/settings.json`.

| file | when it runs | what it does |
| --- | --- | --- |
| `session-preflight.sh` | SessionStart, UserPromptSubmit | The turn-1 context injection: holds that bind the project (a load hold, or one naming the project, its repo or its lab projects; the rest are one count line), then in priority order the anchor's key facts (decisions log as one pointer line; no Lab, Links or empty Blockers), a dispatched session's own queue item row, only the lessons that match its work (cut at a sentence end; none when nothing matches), plans, one count line for the other sessions open in the checkout, and an app's commits (scoped to its subtree; a whole repo's are Claude Code's gitStatus), with no gh call and no queue write, under one 9,000 B budget that names whatever it left out. On a session's first prompt of three words or more it adds the top 3 lessons that prompt matches, less the ones turn 1 carried; a later prompt adds nothing. Non-blocking. |
| `project-name.sh` | sourced | Resolves a directory to its canonical project name via `project-map.json`. |
| `worktree-create.sh` / `worktree-remove.sh` | WorktreeCreate / WorktreeRemove | Put harness-made worktrees (Agent `isolation: "worktree"`, `--worktree`, background sessions) at `~/.worktrees/<repo>-<name>` instead of `<repo>/.claude/worktrees/`. Remove never forces, so a dirty tree survives. |
| `compact-prep.sh` | PreCompact | Archives the transcript and drops the pending marker the `/compact-prep` skill reconciles against. |
| `archive-stale-plans.sh` | manual | Archives stale per-project plan dirs, and `_live` plans with every phase done or deferred and untouched more than 14 days into `_archive/_live`, taking their links along. |

The Stop side lives in `.claude/hooks/` (`pre-stop-checks.sh` plus `stop-checks.d/` and `stop-post.d/`), not here.

## Deploying: merged is not live

These files reach `~/.config/shared-hooks/` through **`stow --no-folding .`, run from `~/.dotfiles`** - one symlink per file, not one symlink per directory (the private overlay needs to contribute siblings into the same dirs). See `apply_dotfiles()` in `.local/src/installation_scripts/base_functions.sh`.

The consequence is the thing to remember: **merging a new hook file does not deploy it.** The file only becomes live once the working tree is on a commit that contains it *and* stow has run. Until then `~/.config/shared-hooks/` simply has no link for it, and nothing tells you.

That gap is real and has bitten this repo. #123 added `focus-lib.sh` and made the preflight source it; on a machine whose checkout reached that commit before stow ran, the preflight sourced a file that was not there. Under `set -euo pipefail` that exits the script before it prints anything, so turn 1 arrived with **no anchor, no plans, no lessons, no git context, and no error anyone could see**. #124 fixed it by guarding the source and skipping the Focus block when the lib did not load, trading a small visible loss for a silent total one.

So, two rules for anything added here:

- **Guard every optional sibling you source.** `if [ -r "$LIB" ]; then . "$LIB"; fi`, then gate the code that needs it on `declare -F <fn>`. A hook that dies takes the whole injection with it, and the symptom is silence.
- **End no `$(...)` section on a bare `[ test ] && echo`.** When the test is false the subshell exits 1, and under `set -e` the assignment kills the hook. Use `if ...; then echo; fi`.
- **After merging a new file, run `stow --no-folding .`** and verify the link exists, rather than assuming the merge deployed it. It is idempotent, so re-running it is always safe.

Verify a deploy with:

```sh
ls -l ~/.config/shared-hooks/                    # every file linked?
CLAUDE_PROJECT_DIR=~/.dotfiles bash ~/.config/shared-hooks/session-preflight.sh </dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' | head -40
```

An empty or truncated result means a partial deploy, not an empty project.

## Focus and the queue item

`## Focus` is the human's list, so turn 1 does not carry it (it cost about 850 chars in nearly every session) and no hook reads or writes it; `notes focus add|start|done` owns the vault. An agent's own task goes on its agent-queue item, and `agent-land` is what holds it there: no item, no landing (`.local/bin/agent-land` header).

## Tests

`tests/unit/session_preflight.bats` covers each turn-1 cut with a negative control; `tests/integ/preflight_focus.bats` covers what turn 1 carries: the byte budget, the lessons lane, and that the board, the Focus list and an unscoped commit list stay out.

Run them with `make -C tests test-files FILES="unit/session_preflight.bats integ/preflight_focus.bats"`. See the `shell-test-harness` skill before adding more.
