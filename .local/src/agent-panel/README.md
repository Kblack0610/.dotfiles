# agent-panel

A cross-platform tmux chooser for running Claude / AI agents. Lists every tmux
window running an agent, grouped by project, with a live status glyph and a
preview pane — pick one with fzf and jump to it. A magenta `P` after the glyph
marks an agent in plan mode, read from the transcript's latest `permissionMode`.
A blue `A` beside it marks an agent with a pending ask: a file under
`~/.agent/asks/<project>/` (or `$AGENT_ASK_DIR`) with `status: pending` whose
`claude_session` is this agent's session id. That is the same rule as `asks_for` in
`fleet-sessions`, so the panel marks exactly the sessions it buckets as NEEDS.

`agent-panel asks-human <transcript.jsonl>` exits 0 when a session's last word asks you
something. The Stop check `.claude/hooks/stop-post.d/88-ask-filed.sh` uses it to make the
session file that question as an ask, so the ask stays the one record and no view guesses from
the chat. The rule (`asks_human` in `jsonl.rs`): the last main-thread entry is the session's
own, with no prompt or tool result after it, and either:

- that entry's last call is a dialog left open (`AskUserQuestion`, `ExitPlanMode`), or
- its closing paragraph asks a question: a sentence ending in `?`. A `?` inside backticks,
  double quotes, a code fence or a `>` quote does not count, nor does one in a list item with
  text after it (a findings list answering its own question). A one-line postscript with no
  question ("the screenshot is at X") does not hide the paragraph before it. Pure manners
  ("anything else?", "any questions?") do not count, or
- it hands you a step: one of its last two blocks is a fenced `! <command>` line, or the
  closing paragraph says "when that's done", "once you've", "let me know when" and the like.

`agent-panel time-use <transcript.jsonl>` prints the session's closed time by what it waited on, as one JSON object, the same numbers as `time_use` in `list --json`; the nightly session-outcomes run reads it. The rule is in `.local/src/docs/fleet-states.md`, and `~/.config/agent-panel/time-use.conf` says which commands are a gate or a test.

`shell` keeps the yellow `~`: Claude is at its prompt, but waiting on its own background job
(usually a gate), and resumes by itself when it ends, so it does not need you. The `A` column
is what says it does.

Bound in `~/.tmux.conf`:

- `Prefix + g` — interactive chooser (fzf popup)
- `Prefix + G` — jump straight to the next agent needing attention: waiting at a
  prompt (`!`) or holding a pending ask (`A`)
- `Prefix + y` - the questions panel: every pending question, its card, answered in place (`.local/src/tmux/questions.sh`)

Arriving at a session with an `A` shows a status-line notice for a few seconds: the
question and "Prefix y to answer". It is never a popup, so keys still go to the pane. The
`client-session-changed` hook runs `agent-panel ask-here` (an attach, including the hop
from another server, sets the session too), and `Prefix G` runs it after its jump. The
chooser preview prints the card above the pane tail.

In the chooser:

- The shepherd sits in its own `shepherd` group above every project: the agent in the shepherd's window (`FLEET_SHEPHERD_SESSION`:`FLEET_SHEPHERD_WINDOW`, default `hub:shepherd`, where every pass runs), or any agent holding the live shepherd lease. A pass idle past its lease stays pinned.
- `C-s` goes to the shepherd pass running now, through `fleet-shepherd open` (the same as `Prefix o`).
- The list is on top at full width and the preview below it. `C-/` switches the preview to the right of the list, then hides it, then brings it back. `PANEL_LAYOUT=side` (`set-environment -g PANEL_LAYOUT side` in `.tmux.conf`) opens it on the right instead, for this and every other panel: the layout is `panel_fzf_layout` in `../tmux/panel-lib.sh`, and `tests/shared_layout.rs` holds agent-panel to the same strings.
- The preview shows, top to bottom: the pending question card, the session's last message in full, its last tool call, and the last 12 pane lines (for a permission dialog or live prompt, which only the pane shows).

## Why a binary (replacing the old bash scripts)

This replaces `../tmux/agent-chooser.sh` + `agent-preview.sh`, which only ran on
Linux. Two reasons they broke on macOS:

- They used bash 4 associative arrays (`declare -A`); macOS ships bash 3.2.
- They mapped tmux panes to Claude sessions by walking `/proc`, which macOS lacks.

This binary gets the process tree from `ps -axo pid=,ppid=` (portable across
macOS/BSD and Linux/procps) and does all parsing in pure Rust, so behaviour is
identical on both. **fzf and tmux remain the UI** — only the fragile core was
rewritten.

How an agent is detected is deliberately robust: a pane is a Claude agent when
its process tree contains a pid that has a `~/.claude/sessions/<pid>.json` file.
This works even where tmux reports `pane_current_command` as the Claude version
string rather than `claude` (observed on macOS).

## Subcommands

| Command | Purpose |
|---------|---------|
| `agent-panel` (default) | Interactive chooser; spawns fzf, jumps on selection |
| `agent-panel next` | Cycle to the next attention-needed agent, `!` or `A` (else next in list) |
| `agent-panel asks-human <transcript>` | Exit 0 when the transcript's last word asks the human something, else 1 (the Stop check `88-ask-filed.sh`) |
| `agent-panel list` | One TSV row per agent: `target glyph project summary` |
| `agent-panel list --json` | One JSON object per agent: target, pane, status, cwd, session_id, plan_mode, idle_since (the newest transcript entry timestamp, the file mtime only when none has one), context_tokens, model, plan_file, edited_files (paths changed through Edit, Write, MultiEdit, NotebookEdit) (read by `fleet-sessions`), and what an action needs: server, tmux_session, window_id, pid, account (claude-acct's name for the claude's `CLAUDE_CONFIG_DIR`), attached, parked, plan (the plan slug), ask (the pending ask id or null). `--parked` adds a row per `claude-acct park` ledger whose session has no live claude, and puts the attached sessions first |
| `agent-panel ask-here --socket S --client C --session S --window W` | Status-line notice with the question of the agent in that window, else in that session; silent when none asks |
| `agent-panel jump <target>` | Jump to a `list` target (same-server switch or cross-server hop) |
| `agent-panel preview --map-file <f> <row>` | Internal fzf preview callback |

## Multiple tmux servers

Sessions are split across tmux servers, one per socket (`hub`, `lab`, ... see
`../tmux/servers.sh`). A bare `tmux` only reaches the server `$TMUX` points at, or the
`default` socket from outside tmux, which is not used here. So agent-panel lists every
live socket in the tmux socket dir, calls each with `tmux -L <server>`, and names a
target `<server>/<session>:<window>`. A jump inside the current server is a
`switch-client`; anything else goes through `tmx goto <server> <session:window>`,
which owns the detach-and-attach hop and the Prefix+L way back.

## Layout

- `procmap.rs` — `ps`-based process table + pane→Claude pid mapping (the `/proc` replacement)
- `tmux.rs` — `tmux` CLI wrappers per server (list-panes, capture-pane, jump)
- `session.rs` — read `~/.claude/sessions/<pid>.json`; status glyph; at-the-prompt test; JSONL path
- `jsonl.rs` — tail the transcript; row summary, plan mode, a closing question, the last message for the preview
- `asks.rs` — which Claude sessions own a pending ask (`agent-ask`)
- `render.rs` — project grouping, ANSI fzf rows, preview formatting
- `fzf.rs` — spawn fzf with the rows + preview/next callbacks
- `chooser.rs` — orchestration for the three entry points
- `main.rs` — clap dispatch

## Build & install

Built and symlinked automatically by the dotfiles installer
(`build_local_rust_tools` in `installation_scripts/base_functions.sh`). Manually:

```sh
cargo build --release
ln -sf "$PWD/target/release/agent-panel" "$HOME/.local/bin/agent-panel"
```

Requires `tmux` and `fzf` on `PATH`.

```sh
cargo test     # unit tests (parsing, mapping, rendering)
cargo clippy
```
