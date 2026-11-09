# agent-panel

A cross-platform tmux chooser for running Claude / AI agents. Lists every tmux
window running an agent, grouped by project, with a live status glyph and a
preview pane — pick one with fzf and jump to it. A magenta `P` after the glyph
marks an agent in plan mode, read from the transcript's latest `permissionMode`;
a bold white `M` in the same column marks manual (`default`) mode, which `manual-mode-investigate.sh` makes investigate-only, so that tab answers and does no work on its own. The preview's status line says `plan mode` or `manual mode` the same way.
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

The chooser preview shows the same card under `needs you`.

In the chooser:

- The shepherd sits in its own `shepherd` group above every project: the agent in the shepherd's window (`FLEET_SHEPHERD_SESSION`:`FLEET_SHEPHERD_WINDOW`, default `hub:shepherd`, where every pass runs), or any agent holding the live shepherd lease. A pass idle past its lease stays pinned.
- `C-y` lists only the sessions waiting on you (a pending ask or a prompt), and again lists every session; the prompt reads `Asking only >` while it is on, and the label keys keep the view.
- `C-s` goes to the shepherd pass running now, through `fleet-shepherd open` (the same as `Prefix o`).
- Each row shows how long the session has been open (`45m`, ` 3h`, ` 2d`: since its claude process started, so a resume restarts it; blank on a parked row) before its target.
- Typing finds a session by what it has been about, not only its row: every typed word must appear in the row, the project, or the session's past titles, first and last prompt, branch and touched files from the sessions index (`~/.agent/sessions/index.tsv`, the one Prefix+R searches), case-insensitive. A word that names a topic in `~/.config/agent-panel/topics.conf` also matches that topic's words, so `audio` finds the session that only said `music`. The panel matches (`src/search.rs`), not fzf, so there is no fuzzy match and fzf's `!`, `^` and `$` operators do not apply. `A-n` jumps to the next agent needing attention (a bare key would not type into the search). Opening the panel refreshes the index in the background, so titles from since the last open are searchable on the next one.
- `C-o` steps the sort: by project (grouped, the default), longest open first, needs you first, stalled first. Any sort but project is one flat list, each target led by its project. `A-o` reverses the sort. The panel reopens in the sort it was left in, saved in `${XDG_STATE_HOME:-~/.local/state}/panels/agent-panel.sort` (`src/sort.rs`).
- The list is on top at full width and the preview below it. `C-/` steps stacked -> side by side -> hidden -> stacked, and the panel reopens in the layout `C-/` last left it in, hidden included. The layout is `panel_fzf_layout` in `../tmux/panel-lib.sh`, shared with every other panel: agent-panel runs `~/.local/src/tmux/panel-layout.sh args agent-panel` for its fzf arguments, and `tests/shared_layout.rs` checks they reach fzf as printed.
- The preview scrolls on the keys every panel shares, from that same layout: `C-d`/`C-u` half a page, `PgDn`/`PgUp` a page, and fzf's own `S-Down`/`S-Up` and the mouse wheel.
- The preview reads summary first (`render::preview`), each part under a bold title and a dim rule: one status line (target, worktree, status, plan mode, how long open, account) and the pane title; `needs you` (amber, the only colour) with the same card the questions panel shows, the ask's (`agent-ask card`) and the open plan or question dialog's (`agent-panel dialog`); the last tool call on one line; the last message in full as plain text (`agent-panel plain`); last the bottom 8 pane lines above Claude Code's input box and status bar, for a permission prompt or a live spinner. When a dialog card shows, the pane part is left out: it is the same dialog. Changed 2026-11-07 (ar-690, ar-691): the `question` title is now `needs you` and also carries an open dialog; the last tool moved above the last message; the pane tail went from 12 lines with colour and chrome to 8 plain lines without them.

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
| `agent-panel next` | Jump to the next agent that needs you: `!` (a dialog or prompt open, a plan to approve included) or `A`. Plan mode alone waits on nothing, as `fleet-sessions` reads it. With none, says `no session needs you` and stays put |
| `agent-panel asks-human <transcript>` | Exit 0 when the transcript's last word asks the human something, else 1 (the Stop check `88-ask-filed.sh`) |
| `agent-panel list` | One TSV row per agent: `target glyph project summary`. Exit 3, after the rows it could read, when the read had a gap (a live tmux server's `list-panes`, `ps`, or a live claude's session file failed; each named on stderr): the list may miss a live session, so a caller must not read a missing session as gone |
| `agent-panel list --needs` | The same with a fifth column, `1` when the agent needs the human now (a dialog or a pending ask), else `0`: what the tmux status line counts |
| `agent-panel list --json` | One JSON object per agent: target, pane, status, cwd, session_id, plan_mode, idle_since (the newest transcript entry timestamp, the file mtime only when none has one), context_tokens, model, plan_file (its plan-mode `planFilePath`, else the plan it last wrote by Write, Edit or a shell redirect, `tee`, `sed -i` or `agent-land --plan` into `~/.claude*/plans`, else one its prompt named before its first reply; a plan it only read or quoted is not its plan), edited_files (paths changed through Edit, Write, MultiEdit, NotebookEdit) (read by `fleet-sessions`), and what an action needs: server, tmux_session, window_id, pid, account (claude-acct's name for the claude's `CLAUDE_CONFIG_DIR`), attached, parked, plan (the plan slug), ask (the pending ask id or null). `--parked` adds a row per `claude-acct park` ledger whose session has no live claude, and puts the attached sessions first |
| `agent-panel jump <target>` | Jump to a `list` target (same-server switch or cross-server hop) |
| `agent-panel said <transcript> --around <ask id>` | JSON `{first, prompt, said}` for the turn whose tool result printed the ask id on its own line: the session's first typed prompt, the prompt that turn answered, and its own text blocks, oldest first. Exit 1 when no turn printed the id. The question card's story (`agent-ask card`) |
| `agent-panel send --pane <server>/<pane> [--no-submit] <text>` | Type a message into a Claude pane: the one implementation (agent-web's send box and `agent-ask answer` both use it). Bracketed paste, Enter only once the input box has drawn the paste and held still, a second Enter if the box did not change, exit 3 if it still did not (the text is in the input box). It judges only Claude Code's input box (the lines between the last two rules), so a busy pane's spinner passes for neither; a pane with no box is judged whole |
| `agent-panel dialog <target> [--options]` | The card for the plan or question dialog open in that pane, read off the live screen (`dialog.rs`): kind, title, the options as the pane numbers them, and for a plan the plan text from the transcript. `--options` prints `key<TAB>free<TAB>text`, free 1 for an option that takes typed text. Exit 1 when no dialog it can read is open (the questions panel then shows the pane) |
| `agent-panel answer <target> <key> --expect <text> [-- <typed>]` | Press option `<key>` in that dialog, after a fresh capture shows it still reads `<text>`; an option that takes text gets `<typed>` pasted and Enter. Exit 0 sent, 3 the pane did not move on, 4 the dialog changed or closed (nothing sent). The questions panel (Prefix+y) answers plans and questions with it; hub-tui's plan approval reads the same parser |
| `agent-panel plain [--width N]` | Markdown on stdin as plain text (`md.rs`): heading, bold and backtick marks and code fences gone (the code kept, indented), a table as one `header: value; ...` line per row, folded at `N` (default `$FZF_PREVIEW_COLUMNS`, else `$COLUMNS`, at most 110; `0` folds nothing) with list items hung. The one markdown cleaner: the preview's last message, the dialog card's plan and `agent-ask card`'s story read through it |
| `agent-panel preview --map-file <f> <row>` | Internal fzf preview callback |

## Multiple tmux servers

Sessions are split across tmux servers, one per socket (`hub`, `lab`, ... see
`../tmux/servers.sh`). A bare `tmux` only reaches the server `$TMUX` points at, or the
`default` socket from outside tmux, which is not used here. So agent-panel lists every
live socket in the tmux socket dir, calls each with `tmux -L <server>`, and names a
target `<server>/<session>:<window>`. A jump inside the current server is a
`switch-client`; anything else goes through `tmx goto <server> <session:window>`,
which owns the detach-and-attach hop.

## Layout

- `procmap.rs` — `ps`-based process table + pane→Claude pid mapping (the `/proc` replacement)
- `tmux.rs` — `tmux` CLI wrappers per server (list-panes, capture-pane, jump)
- `session.rs` — read `~/.claude/sessions/<pid>.json`; status glyph; at-the-prompt test; JSONL path
- `jsonl.rs` — tail the transcript; row summary, plan mode, a closing question, the last message for the preview
- `dialog.rs` - read an open plan or question dialog off a pane capture, and answer it with keys
- `asks.rs` — which Claude sessions own a pending ask (`agent-ask`)
- `render.rs` — project grouping, ANSI fzf rows, preview formatting
- `md.rs` - markdown to plain text at a width (`agent-panel plain`)
- `sort.rs` - the sort keys, their order and the saved sort
- `fzf.rs` — spawn fzf with the rows + preview/next callbacks, and the shared preview layout from `panel-layout.sh`
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
