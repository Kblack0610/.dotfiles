# Panel conventions

How to write a tmux panel in this repo, and why each rule is the way it is.

`README.md` is user-facing: which key opens what. This file is contributor-facing: the rules a
new panel follows. Two audiences, two docs - which is also what stops the README's key table
from drifting again, since it no longer has to carry conventions.

**Start by copying `_skeleton.sh`.** It is runnable (`_skeleton.sh --list` prints rows,
`_skeleton.sh` opens a picker) and it already satisfies every rule below. A template you can
execute beats a document nobody opens; this file exists for the *reasons*, which a test can
never express.

## What is enforced, and where

| Rule | Enforced by |
|---|---|
| manifest row exists; closure with `.tmux.conf` both ways | `tests/integ/panel_conformance.bats` |
| geometry in vocabulary, non-empty, `-E` present | same |
| no inline shell in a bind | same |
| strict-mode preamble, absolute `$SELF`, no bare `$0`, no truecolor | same (countdown ratchets) |
| library behaviour: palette, fzf dialect, `$TMUX` handling, `fail` vs `die` | `tests/unit/panel_lib.bats` |

A rule not in that table is advice. A rule in it will stop your PR.

## The preamble - exactly two lines

```bash
SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1
```

**`${BASH_SOURCE[0]}`, never `$0`.** The unit tier *sources* a panel to test its functions,
and under `source` `$0` is the bats runner - so `realpath "$0"` would resolve to the wrong
file and the sibling lookup would fail. `${BASH_SOURCE[0]}` is correct executed *and* sourced.

**`realpath`, not `readlink -f`.** `-f` is a GNU extension missing from older macOS, and this
repo is shared with a Mac.

**`$SELF` is the caller's line, not a library function.** You cannot call `panel_self()`
before you know where the library is. One honest line beats a probe loop.

**Why absolute at all:** fzf `--bind` re-invokes the script from *inside* the picker, where
`$0` may be relative and `PATH` is whatever the tmux server had - not an interactive shell's.
`favourites.sh:26` is the live counter-example (`SELF="$0"`, re-invoked from five actions).

## `set -uo pipefail`, and deliberately no `-e`

`-u` turns a typo'd variable into a stop instead of an empty string. `pipefail` because these
scripts are pipelines end to end.

`-e` is **absent on purpose**, in all eleven panels. A `grep -q` miss and a failing command
substitution are ordinary control flow here, so `-e` aborts a picker mid-render. If you "fix"
this, panels start dying on ordinary misses. `tests/unit/panel_lib.bats` asserts `errexit` is
*off*, so the omission cannot be quietly reverted.

Migrating a script *to* strict mode is the single riskiest edit in this area: a latent unset
read that today yields an empty string will now abort. Exercise **every verb by hand**, not
just the tier.

## Config: a rule, not a function

Every tunable is `${VAR:-default}` at the top of the script.

- **No** sourced sibling `.conf`.
- **No** `$HOME/.dotfiles/...` literal. `pr-viewer.sh:18` used to have one, and it broke the
  moment the repo moved - and, worse, made the script untestable, because a fixture could not
  redirect it. It now uses `${PR_REPOS_CONF:-$PANEL_DIR/pr-repos.conf}`: correct under stow,
  overridable from the sandbox, and `integ/pr_viewer.bats` asserts the key is actually read
  rather than merely present.

`$PANEL_DIR` is the realpath'd directory of the running script, so it is right under stow.

**A data file that names machine-specific paths must be machine-independent.** The
`.config/tmux-servers/*.conf` manifests are the case in point: they are identical on every
host, and `cmd_ensure` skips (and counts) any entry whose directory does not exist, so each
machine materialises only its own subset. Do not fork such a file per host, and do not
fall back to a default path when the declared one is missing - a fallback silently
produces a wrong-but-plausible result, which is exactly how a `home-config` session ended
up rooted at `$HOME` on a machine that never had the repo.

## Colour: ANSI indices only

Use the `C_*` names from the library. Never emit `38;2;R;G;B` or `38;5;N`.

This is the rule most likely to be "improved" by someone reaching for nicer colours, so: the
panels are theme-responsive **because** they use indices. `theme-switch` recolours the
*terminal's* palette, so `\033[1;32m` follows a theme swap for free. A hex triple pins the
surface to one theme and **stops** it tracking the terminal - a regression that presents as a
feature. Enforced by both test files.

The `$'..'` form matters too. `pr-viewer.sh` used to define its own palette with single-quoted
`'\033[..'`, which needs `printf %b` - so the first person to reach for `%s` printed a literal
`\033`. Taking `C_*` from the library removes the choice.

`PANEL_NO_COLOR` (and `NO_COLOR`) blank the palette, which is what lets assertions skip
`strip_ansi`.

## `panel_fail` vs `panel_die`

`fail` returns 1; `die` exits 1. The distinction is load-bearing, and is `tags.sh:66`'s rule:

> A helper running inside a command substitution MUST use `fail` + `return 1`. An `exit` there
> kills only the subshell, leaving the caller to carry on with an **empty result** - and for a
> filter, to silently fall back to matching everything.

Both route through `panel_warn`, which writes to **stderr always** plus a best-effort
`tmux display-message`. Not either/or: these scripts are CLIs that other scripts and agents
call, and they need the reason, not just an exit code. The flash is additive, for keybindings.
`favourites.sh:34` gets this backwards - it *replaces* stderr with the flash.

## Dependencies: die or degrade, never assume

- `panel_need fzf` - the surface cannot render at all without it.
- `panel_have x || panel_hint 'x not on PATH'` - one *section* degrades. `fleet.sh:199` is the
  model and is better behaviour than dying; prefer it when the panel still has something to
  show.

What is not acceptable is neither: `favourites.sh:241` uses `jq` unchecked two lines after
checking `sqlite3`. `pr-viewer.sh` used to check `gh auth status` while never checking `gh`,
so a machine without `gh` at all reported an authentication problem; it now does
`panel_need gh` first, then the credential.

## fzf: one dialect

```bash
panel_fzf_opts                       # PANEL_FZF_OPTS=(--ansi --reverse --border)
panel_fzf_table                      # PANEL_FZF_TABLE=(--cycle --no-sort --wrap --delimiter=TAB)
"$(panel_fzf_preview left 24)"       # --preview-window=left,24%,border-right,wrap
```

**Arrays, never a flag string.** The sandbox path contains a space *by design*
(`tests/helpers/sandbox.bash:32`), so a re-split string is exactly the bug that harness exists
to catch.

**The modern comma form**, via `panel_fzf_preview`. The legacy colon form
(`left:24%:wrap:border-right`) is spelled three different ways across the tree today.

`--no-input`, and anything modal, stays per-surface. It is a navigation decision, not a floor.

In every action, re-invoke `"$(printf '%q' "$SELF")"` - never a bare script name (that depends
on `PATH`, which a popup does not guarantee) and never a bare `$0`.

## The script owns its border

`panel_fzf_opts` includes `--border`, and the bind passes `-B` so tmux draws none. Exactly one
of them should draw, and making it the *script* is the better half of the choice here, because
`cockpit.sh:74-80` reuses `notes-cockpit.sh` and `pr-viewer.sh` as **window** commands where
there is no popup border at all. A surface that renders identically in a popup, in a cockpit
window, and from a bare shell is one fewer thing to reason about. `bind g` + `agent-panel` has
shipped this pairing all along.

## Dispatch: always reject an unknown verb

```bash
case "${1:-}" in
--list) cmd_list ;;
'')     cmd_pick ;;
-h|--help) panel_usage ;;
*)      panel_die "unknown verb: $1 (try --help)" ;;
esac
```

`notes-cockpit.sh:915` and `fleet.sh:320` have **no default arm**: an unknown verb falls
through to the fzf UI. So a typo opens a picker instead of erroring, and in a headless test it
blocks *forever* rather than failing. Do not copy that shape.

`panel_usage` prints the header block with no hardcoded line range - unlike
`servers.sh:436`'s `sed -n '2,40p'`, which silently truncates once the header outgrows it. So
write the header as the help text.

## The test seam stays copy-pasted

```bash
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0
```

Above the dispatch, below the definitions. It is **not** a library function because `return`
must execute at the script's top-level scope; wrapped in a function it would only exit that
function. This is the one duplication the library deliberately keeps.

## Geometry lives in `.tmux.conf`

Three named sizes, as `%hidden` constants:

| name | `-w` / `-h` | for |
|---|---|---|
| `FULL` | 100% / 100% | owns the screen; dense multi-column TUI |
| `WIDE` | 90% / 85% | multi-column table, or anything with a preview |
| `SMALL` | 80% / 60% | one-column pick-one list, or read-and-dismiss |

A size should state the surface's **shape**. Six sizes encoded no distinction a reader could
name, which is why they drifted.

Three facts verified in the container on **both tmux 3.7b and 3.4**, not assumed:

- `%hidden PW_WIDE=90%` **does** expand in flag-argument position. So the vocabulary is a real
  named constant in the file the bindings live in - no emitter, no wrapper, no plugin.
- One constant **per flag**. A variable holding a whole flag group (`"-w 90% -h 85%"`) drops
  the bind entirely, because tmux expands `$VAR` to a single token.
- An **undefined** variable neither errors nor drops the bind: `-w $TYPO` registers `-w ''`, an
  empty geometry, silently, with no diagnostic at load. Nothing tells you until you press the
  key - which is why the conformance test asserts non-empty as well as in-vocabulary.

## The popup itself cannot be tested

`display-popup` draws a client-side overlay onto `client->tty`. Headless it fails
`no current client` rc=1 and **the command never runs**; even with a pty client attached it
never appears in `list-panes` and `capture-pane` cannot read it.

So: the **bind is text** (asserted), the **script is a process** (asserted), and the overlay is
neither - a human pressing the key is its only test. Put nothing load-bearing in the popup
mechanism, and make every panel runnable as an ordinary pane command, which is how the ui tier
drives them.
