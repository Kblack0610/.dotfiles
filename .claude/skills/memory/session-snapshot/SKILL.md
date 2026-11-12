---
name: session-snapshot
description: >-
  Spin the fleet down before a reboot or upgrade and back up after boot, plus a snapshot of what dies (sessions, servers, containers, dirty repos). Use for "spin everything down", "I want to reboot", "what's running before I reboot", "restore my sessions". One session: wind-down.
metadata:
  category: memory
  tags: [session, reboot, upgrade, inventory]
  reviewed: "2026-11-11"
---

# session-snapshot

Before a reboot you lose every tmux/Claude session, dev server, and non-enabled service.
This skill takes a **decision-oriented inventory** of what's running, separates "comes back on
its own" from "you must restart it manually", flags **uncommitted/unpushed git work** (the only
thing genuinely at risk), writes it all to a dated file in the **notes inbox**, and on the next
boot helps you bring the right things back.

Verbs: **`down`** and **`up`** (the planned reboot), **`snapshot`** (default) and **`restore`** (the inventory and the hand restore).

## Scope and triggers

Before a planned reboot or upgrade, spin the fleet down with one command and let it come back on its own at boot; around that, inventory what dies on reboot (tmux/Claude sessions, dev servers, manual `systemd --user` services, docker containers, dirty/unpushed repos) into a dated checklist in the notes inbox. Use when the user says "spin everything down", "I want to upgrade/reboot this machine", "what's running before I reboot", "save my session state", "restore my sessions". `down` and `up` act; `snapshot` observes; `restore` acts only with confirmation.

## down and up: the planned reboot

```bash
session-snapshot down "kernel upgrade"   # --dry-run first to see what it would set
# ... upgrade, reboot ...
session-snapshot status                  # after boot: "up: no planned reboot in progress" when it came back
```

- `down` holds dispatch (`agent-hold set dispatch`), pauses the agentctl runners (`agentctl pause`), takes a final pane record (`fleet-dispatch record`), and writes the marker `~/.agent/maintenance` with what it set. It sets only what is not already set, so a hold or pause someone else put up is never lifted by `up`. It parks and kills nothing: the reboot stops the sessions.
- At boot, `session-snapshot-up.service` runs `session-snapshot up` only while the marker exists: `fleet-dispatch restore` reopens every recorded conversation, then it resumes agentctl, releases dispatch, clears the marker, and pages one "back up after" line (normal priority when a reopen failed; rerun `fleet-dispatch restore`).
- While the marker exists, `fleet-dispatch record` does not page "tmux server died": the `up` page replaces it.
- Not rebooting after all: `session-snapshot up` by hand undoes it the same way.
- Run `down` last, right before the reboot, after `snapshot` below if the user wants the checklist. Commit or push the dirty repos first; the reboot does not wait for them.
- Unit failed at boot (Sentinel's `systemd-user-failed` pages it): `systemctl --user status session-snapshot-up`, then `session-snapshot up`.

## Where the artifact lives

The checklist goes to the **notes inbox**, not `$HOME` root:

- Full doc: `"$(notes path inbox)/<date>-reboot-restore.md"`
- Triage pointer (so it surfaces in `notes inbox`): `notes inbox add "reboot restore checklist -> <file>"`

Use the resolved path from `notes path inbox`; never hard-code `~/.notes`. Never hand-write into
`~/.notes/journal/` - but the inbox is a capture surface and a standalone dated file there is fine.

## snapshot

Gather, in parallel where possible, then write the dated file + inbox pointer:

```bash
DATE=$(date +%F)                      # the skill is allowed real dates; agents pass one if sandboxed
OUT="$(notes path inbox)/${DATE}-reboot-restore.md"

# 1. tmux sessions/windows (cwd + live branch + foreground cmd), on EVERY live named server.
#    The worlds (hub, lab, ...) are named sockets and a bare `tmux` reaches only one of them, so
#    walk the socket dir like panel_live_servers (.local/src/tmux/panel-lib.sh). list-windows
#    fails on a socket file whose server is gone, which skips it. Tab-separated, the server
#    first and the path last: the path is the field step 6 takes, and it may hold spaces.
for sock in "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"/*; do
  [ -S "$sock" ] || continue
  srv=${sock##*/}
  tmux -L "$srv" list-windows -a -F "$srv"$'\t''#{session_name}:#{window_index}'$'\t''[#{pane_current_command}]'$'\t''#{pane_current_path}' 2>/dev/null
done

# 2. Claude sessions
ps -eo pid,etime,cmd | grep -E '[c]laude ' | grep -v claude-1000

# 3. systemd --user: RUNNING now vs ENABLED (enabled => auto-start; running-but-not-enabled => manual)
systemctl --user list-units --type=service --state=running --no-legend | awk '{print $1}'
systemctl --user list-unit-files --state=enabled --no-legend | awk '{print $1}'
#   -> anything running but NOT enabled is the "restart manually" list (e.g. agentctl@sentinel)

# 4. dev servers / runtimes (filter noise: tsserver, ASR, language servers)
ps -eo pid,etime,cmd | grep -iE '[v]ite|[n]ext|[w]ebpack|[n]ode .*dev|turbo run dev|[u]vicorn|[f]lask|[c]argo run|[b]un ' \
  | grep -viE 'tsserver|typingsInstaller|whisper|parakeet|asr'

# 5. docker containers + restart policy (no policy => won't come back)
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
for c in $(docker ps -q); do printf '%s\t%s\n' "$(docker inspect -f '{{.Name}}' $c)" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $c)"; done

# 6. dirty/unpushed git across the repos the sessions live in (THE at-risk list)
for d in <dirs from steps 1-2: the last tab field of a step 1 row>; do
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
  printf '%-45s [%s] dirty=%s unpushed=%s\n' "$d" "$(git -C "$d" branch --show-current)" \
    "$(git -C "$d" status --porcelain | wc -l)" "$(git -C "$d" log --oneline @{u}.. 2>/dev/null | wc -l)"
done

# 7. Cross-check: sessions with a transcript written in the last 30 min that the fleet has no live row for.
#    ps and tmux miss a session in a detached or closed window; its transcript still shows it. A live
#    session idle for longer is in steps 1-2, so the window only has to cover a session that just died.
#    All account dirs; a subagent file (<session>/subagents/agent-*.jsonl) maps to its parent session.
WINDOW_MIN=30
{ fleet-sessions --json | jq -r '.session_id // empty'; echo "$CLAUDE_CODE_SESSION_ID"; } > /tmp/snap-known.$$
find ~/.claude*/projects -name '*.jsonl' -mmin -$WINDOW_MIN 2>/dev/null | while read -r f; do
  case $f in */subagents/*) sid=$(basename "$(dirname "$(dirname "$f")")") ;; *) sid=$(basename "$f" .jsonl) ;; esac
  printf '%s\t%s\n' "$sid" "$(rg -o -m1 '"cwd":"[^"]*"' "$f" | cut -d'"' -f4)"
done | sort -u | awk -F'\t' 'NR==FNR{k[$0];next} !($1 in k)' /tmp/snap-known.$$ -
rm -f /tmp/snap-known.$$
#   -> each line is <session id> <cwd>: a row in "Dies on reboot" marked "from transcript", and its cwd joins
#      the step 6 dirty/unpushed loop. This session itself is excluded.

# 8. Finished or not, per session: the fleet's own verdict, never "PR merged + idle".
fleet-sessions --json | jq -r 'select(.session_id) | "\(.session_id)\t\(.finished)\t\(.bucket)\t\(.blockers | join("; "))"'
```

Write the file with these sections (see the template the skill emits):
- **⚠️ Before reboot** - dirty/unpushed repos (commit/stash prompt)
- **🟢 Auto-restarts (enabled --user units)** - do nothing
- **🟡 Manual restart** - running-but-not-enabled services + dev servers (with exact relaunch cmd + port)
- **🔴 Dies on reboot** - tmux/Claude sessions table (server | session | dir | branch | project | Claude session id | queue item, if it was working one). A session found only by step 7 is listed too (its row says "from transcript", with no tmux server and the cwd from the transcript). The id is what `restore` resumes; the project comes from `resolve_project_name <dir>` (`~/.config/shared-hooks/project-name.sh`), the item from `agent-queue list --json --state active`, the one whose `session` is `<server>:<session>` (a bare name means `lab`).
- **Docker** - containers w/ vs w/o restart policy; note `mcp/filesystem` are ephemeral (Claude respawns)
- **Resume task** - any in-flight task to pick up (e.g. the original reason for rebooting)

Then: `notes inbox add "reboot restore checklist -> $OUT"` and tell the user the path.

**Finished means the plan's phases are done.** A merged PR on an idle pane proves nothing. Take `finished` and `blockers` from step 8 as the verdict (its rule: `.local/src/docs/fleet-states.md`, DONE) and do not restate it here. A `finished false` session is listed unfinished with its `blockers`. A session with no step 8 row (a "from transcript" one) has no verdict: list it unfinished and read the last assistant message in its transcript (`claude-recall show <id>`) for what it was doing.

Key classification rule: **running ∧ ¬enabled = manual restart**. Enabled units auto-start; don't
list them as action items. Ephemeral `mcp/filesystem` containers are noise - Claude respawns them.

## restore

After an unplanned reboot (a planned one used `up`), or for what `up` does not bring back:

```bash
ls -t "$(notes path inbox)"/*-reboot-restore.md | head -1      # newest checklist
```

Read it, then **with confirmation** offer to:
- bring back the Claude sessions with `fleet-dispatch restore --dry-run`, then `fleet-dispatch restore`. It reads the pane record `fleet-state` keeps each minute, not this checklist, and reopens each conversation as a window of its old session (`fleet-dispatch` skill, "A world server died"). A conversation it could not reopen, or one the record never held, goes through `fleet-dispatch start --project <project> --server <server> --session <name> --window <name> --cwd <dir> --resume <session id> [--item <slug>]`, the one way an agent starts a session. Never `tmux new-session` + `claude --resume` by hand, and never tag a session with `set-option` afterwards.
- recreate other tmux sessions (no Claude in them) on the server their row names: `tmux -L <server> new-session -d -s <name> -c <dir>`
- start the manual services: `systemctl --user start <unit>`
- relaunch dev servers with the captured command line
- `docker start <name>` for DBs that lacked a restart policy
- surface the dirty repos again so nothing was lost

Never auto-kill or auto-restart without an explicit go-ahead. Confirm the batch, then act.

## Notes

- The skill may use real `date`; in a sandboxed agent context, accept the date as an argument.
- Don't touch auth tokens, sqlite, or other runtime state.
- Pairs with `wind-down` (single-session teardown). This skill is host-wide: every session at once.
