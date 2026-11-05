# shared-hooks

The cross-tool session hooks. Claude Code is the main consumer, but nothing here is Claude-specific: they are plain bash, read their input from stdin as JSON, and are wired up in `.claude/settings.json`.

| file | when it runs | what it does |
| --- | --- | --- |
| `session-preflight.sh` | SessionStart | The turn-1 context injection: holds, stranded sprints, then in priority order the anchor's key facts (decisions log as one pointer line), the agent board (6 rows), the lessons digest, plans, an app's commits (scoped to its subtree; a whole repo's are Claude Code's gitStatus) and PRs, under one 9,000 B budget that names whatever it left out. Non-blocking. |
| `focus-lib.sh` | sourced | The one parser for the daily note's `## Focus` section. Used by the reconcile gate. Read-only by contract. |
| `project-name.sh` | sourced | Resolves a directory to its canonical project name via `project-map.json`. |
| `worktree-create.sh` / `worktree-remove.sh` | WorktreeCreate / WorktreeRemove | Put harness-made worktrees (Agent `isolation: "worktree"`, `--worktree`, background sessions) at `~/.worktrees/<repo>-<name>` instead of `<repo>/.claude/worktrees/`. Remove never forces, so a dirty tree survives. |
| `compact-prep.sh` | PreCompact | Archives the transcript and drops the pending marker the `/compact-prep` skill reconciles against. |
| `archive-stale-plans.sh` | manual | Archives stale per-project plan dirs. |

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

## The Focus loop

`## Focus` is the human's list, so turn 1 does not carry it (it cost about 850 chars in nearly every session). An agent's own task goes on its agent-queue item.

- **End of turn** - `.claude/hooks/stop-post.d/86-focus-reconcile.sh` blocks **once per session** when a turn did real work (dirty tree, or HEAD moved) while nothing is marked `[/]` in progress and no `notes focus` write landed since the last run.

Keep one item marked in progress and the gate never fires. That is the intended pressure: declare what you are on, and it disappears. Escape hatch: `CLAUDE_SKIP_FOCUS_GATE=1`.

The gate parses `## Focus` through `focus-lib.sh`, the one parser; a second parser drifted once and dropped every in-progress `- [/]` item (#109).

Writes are never done from a hook. `notes focus add|start|done` owns the vault; the hooks only read.

## Tests

`tests/unit/focus_lib.bats` covers every checkbox state through the shared parser. `tests/integ/focus_gate.bats` covers the gate's quiet paths as well as its loud one - a gate that fires on idle turns gets trained away within a day. `tests/integ/preflight_focus.bats` covers what turn 1 carries: the agent board, the byte budget, and that the Focus list and an unscoped commit list stay out.

Run them with `make -C tests test-fast`. See the `shell-test-harness` skill before adding more.
