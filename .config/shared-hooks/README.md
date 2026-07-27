# shared-hooks

The cross-tool session hooks. Claude Code is the main consumer, but nothing here is Claude-specific: they are plain bash, read their input from stdin as JSON, and are wired up in `.claude/settings.json`.

| file | when it runs | what it does |
| --- | --- | --- |
| `session-preflight.sh` | SessionStart | The turn-1 context injection: anchor, stranded sprints, plans, lessons, last night's dream digest, the lab bus readback, today's `## Focus`, recent commits and PRs. Non-blocking. |
| `focus-lib.sh` | sourced | The one parser for the daily note's `## Focus` section. Shared by the preflight and the reconcile gate. Read-only by contract. |
| `project-name.sh` | sourced | Resolves a directory to its canonical project name via `project-map.json`. |
| `compact-prep.sh` | PreCompact | Archives the transcript and drops the pending marker the `/compact-prep` skill reconciles against. |
| `eval-report.sh` | manual | Reads the eval corpus. |
| `archive-stale-plans.sh` | manual | Archives stale per-project plan dirs. |

The Stop side lives in `.claude/hooks/` (`pre-stop-checks.sh` plus `stop-checks.d/` and `stop-post.d/`), not here.

## Deploying: merged is not live

These files reach `~/.config/shared-hooks/` through **`stow --no-folding .`, run from `~/.dotfiles`** - one symlink per file, not one symlink per directory (the private overlay needs to contribute siblings into the same dirs). See `apply_dotfiles()` in `.local/src/installation_scripts/base_functions.sh`.

The consequence is the thing to remember: **merging a new hook file does not deploy it.** The file only becomes live once the working tree is on a commit that contains it *and* stow has run. Until then `~/.config/shared-hooks/` simply has no link for it, and nothing tells you.

That gap is real and has bitten this repo. #123 added `focus-lib.sh` and made the preflight source it; on a machine whose checkout reached that commit before stow ran, the preflight sourced a file that was not there. Under `set -euo pipefail` that exits the script before it prints anything, so turn 1 arrived with **no anchor, no plans, no lessons, no git context, and no error anyone could see**. #124 fixed it by guarding the source and skipping the Focus block when the lib did not load, trading a small visible loss for a silent total one.

So, two rules for anything added here:

- **Guard every optional sibling you source.** `if [ -r "$LIB" ]; then . "$LIB"; fi`, then gate the code that needs it on `declare -F <fn>`. A hook that dies takes the whole injection with it, and the symptom is silence.
- **After merging a new file, run `stow --no-folding .`** and verify the link exists, rather than assuming the merge deployed it. It is idempotent, so re-running it is always safe.

Verify a deploy with:

```sh
ls -l ~/.config/shared-hooks/                    # every file linked?
CLAUDE_PROJECT_DIR=~/.dotfiles bash ~/.config/shared-hooks/session-preflight.sh </dev/null \
  | jq -r '.hookSpecificOutput.additionalContext' | head -40
```

An empty or truncated result means a partial deploy, not an empty project.

## The Focus loop

Two ends, one parser, closing the loop on the daily note's `## Focus` list:

- **Turn 1** - `session-preflight.sh` surfaces what is open and what is in progress, and nudges you to check whether this session's work is on the list.
- **End of turn** - `.claude/hooks/stop-post.d/86-focus-reconcile.sh` blocks **once per session** when a turn did real work (dirty tree, or HEAD moved) while nothing is marked `[/]` in progress and no `notes focus` write landed since the last run.

Keep one item marked in progress and the gate never fires. That is the intended pressure: declare what you are on, and it disappears. Escape hatch: `CLAUDE_SKIP_FOCUS_GATE=1`.

Both ends parse `## Focus` through `focus-lib.sh` on purpose. They used to parse it separately and drifted: the preflight matched only `- [ ]` and silently dropped every in-progress `- [/]` item, hiding exactly the task you were working on (#109).

Writes are never done from a hook. `notes focus add|start|done` owns the vault; the hooks only read.

## Tests

`tests/unit/focus_lib.bats` covers every checkbox state through the shared parser. `tests/integ/focus_gate.bats` covers the gate's quiet paths as well as its loud one - a gate that fires on idle turns gets trained away within a day. `tests/integ/preflight_focus.bats` covers the partial-deploy case above, and two of its tests fail against the unguarded version, which is what makes them worth keeping.

Run them with `make -C tests test-fast`. See the `shell-test-harness` skill before adding more.
