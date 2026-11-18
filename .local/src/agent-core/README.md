# agent-core

The agent session layer, with no UI: every fact about a live Claude or Codex session, read once and defined once. The agent panel (the Prefix+g chooser, `../agent-panel`), hub-core (and through it the hub TUI) and agent-web all read sessions through this crate, so no view re-implements session discovery or a transcript rule and drifts.

## What a session is

A pane is a Claude agent when its process tree contains a pid that has a `~/.claude/sessions/<pid>.json` file. This works even where tmux reports `pane_current_command` as the Claude version string rather than `claude` (observed on macOS). The process tree comes from `ps -axo pid=,ppid=` (portable across macOS/BSD and Linux/procps; macOS has no `/proc`), and all parsing is pure Rust, so behaviour is identical on both.

Sessions are split across tmux servers, one per socket (`hub`, `lab`, ... see `../tmux/servers.sh`). A bare `tmux` only reaches the server `$TMUX` points at, or the `default` socket from outside tmux, which is not used here. So every live socket in the tmux socket dir is listed and called with `tmux -L <server>`, and a target is named `<server>/<session>:<window>`.

`agent::collect` returns one `Agent` per live session; `collect_all` adds a row per `claude-acct park` ledger in `~/.agent/parked` whose session has no live claude and puts the attached sessions first. `collect_read` also returns the read's gaps (a live tmux server's `list-panes`, `ps`, or a live claude's session file that failed), so a caller never reads a missing session as gone.

## The `list --json` contract

`agent::ListRow` is the JSON shape of one session in `agent-panel list --json`, which about 25 shell callers read with `jq`. The type is the contract: its fields are the keys, in alphabetical order, and the test `list_row_keys_are_the_contract` pins the key set. Renaming or dropping a field fails that test; adding one means adding it there too. What each key means is in the `agent-panel list --json` row of `../agent-panel/README.md`.

## Fact rules

- **Ask mark.** A session holds a pending ask when a file under `~/.agent/asks/<project>/` (or `$AGENT_ASK_DIR`) has `status: pending` and its `claude_session` is this session's id (`asks.rs`). That is the same rule as `asks_for` in `fleet-sessions`, so every view marks exactly the sessions it buckets as NEEDS.
- **Asks the human.** `jsonl::asks_human` (the `agent-panel asks-human` subcommand, read by the Stop check `.claude/hooks/stop-post.d/88-ask-filed.sh`) is true when the last main-thread entry is the session's own, with no prompt or tool result after it, and either:
  - that entry's last call is a dialog left open (`AskUserQuestion`, `ExitPlanMode`), or
  - its closing paragraph asks a question: a sentence ending in `?`. A `?` inside backticks, double quotes, a code fence or a `>` quote does not count, nor does one in a list item with text after it (a findings list answering its own question). A one-line postscript with no question ("the screenshot is at X") does not hide the paragraph before it. Pure manners ("anything else?", "any questions?") do not count, or
  - it hands you a step: one of its last two blocks is a fenced `! <command>` line, or a fence sits beside a paragraph saying "run this", "paste" or "your terminal", or the closing paragraph says "when that's done", "once you've", "let me know when", "tell me when" and the like.
- **Time use.** `jsonl::time_use` splits a session's closed time by what it waited on (`time_use` in `list --json`, and `agent-panel time-use`). The rule is in `../docs/fleet-states.md`, and `~/.config/agent-panel/time-use.conf` says which commands are a gate, a test or a build (a `build` counts as `jobs` in the time numbers; only `open_job` reads it apart).
- **Shell wait.** Status `shell` is Claude at its prompt but waiting on its own background job (usually a gate); it resumes by itself when that ends, so it does not need you. The ask mark is what says it does.
- **Needs attention.** `Agent::needs_attention` is the one definition of a session waiting on the human: a dialog or prompt open, or a pending ask. Plan mode alone waits on nothing.

## Layout

- `agent.rs`: the `Agent` record, `collect*`, the parked rows, `ListRow` and `list_rows`
- `procmap.rs`: the `ps` process table, the pane-to-Claude pid mapping, and the codex process under a pane
- `tmux.rs`: `tmux` CLI wrappers per server (list-panes, capture-pane, jump)
- `session.rs`: read `~/.claude/sessions/<pid>.json`; status glyph; at-the-prompt test; transcript path
- `jsonl.rs`: tail the transcript; row summary, plan mode, plan file, a closing question, time use, usage
- `dialog.rs`: read an open plan or question dialog off a pane capture, and answer it with keys
- `asks.rs`: which Claude sessions own a pending ask (`agent-ask`)
- `account.rs`: claude-acct's account name for a claude's `CLAUDE_CONFIG_DIR`
- `parked.rs`: the `claude-acct park` ledgers under `~/.agent/parked`, so a parked session still shows as a row
- `names.rs`: worktree basename, row label, pane title without its glyph (the project is `project_map::project_for_path`)
- `send.rs`: type a message into a Claude pane (`agent-panel send`)
- `vocab.rs`: the bucket vocabulary state.json carries (`vocab`): the bucket order and which are in progress

```sh
cargo test
cargo clippy
```
