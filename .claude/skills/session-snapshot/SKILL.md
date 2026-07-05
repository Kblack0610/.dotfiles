---
name: session-snapshot
description: Snapshot every live working process before a reboot/logout and restore it after. Capture the things that DIE on reboot — tmux/Claude sessions (cwd + branch), dev servers (command line + port), `systemd --user` services split into auto-start-vs-manual, docker containers (with restart policy), and dirty/unpushed git repos — into a dated checklist in the notes inbox, then offer to recreate them. Use when the user says "snapshot running agents/tasks/processes", "what's running before I reboot", "what do I need to bring back up", "save my session state", "restore my sessions", or before any planned reboot/logout. Verbs: snapshot | restore. It OBSERVES and REPORTS, and on restore only acts with confirmation — it never kills sessions or force-restarts on its own.
---

# session-snapshot

Before a reboot you lose every tmux/Claude session, dev server, and non-enabled service.
This skill takes a **decision-oriented inventory** of what's running, separates "comes back on
its own" from "you must restart it manually", flags **uncommitted/unpushed git work** (the only
thing genuinely at risk), writes it all to a dated file in the **notes inbox**, and on the next
boot helps you bring the right things back.

Two verbs: **`snapshot`** (default) and **`restore`**.

## Where the artifact lives

The checklist goes to the **notes inbox**, not `$HOME` root:

- Full doc: `"$(notes path inbox)/<date>-reboot-restore.md"`  (e.g. `~/.notes/inbox/2026-06-30-reboot-restore.md`)
- Triage pointer (so it surfaces in `notes inbox`): `notes inbox add "reboot restore checklist → <file>"`

Use the resolved path from `notes path inbox`; never hard-code `~/.notes`. Never hand-write into
`~/.notes/journal/` — but the inbox is a capture surface and a standalone dated file there is fine.

## snapshot

Gather, in parallel where possible, then write the dated file + inbox pointer:

```bash
DATE=$(date +%F)                      # the skill is allowed real dates; agents pass one if sandboxed
OUT="$(notes path inbox)/${DATE}-reboot-restore.md"

# 1. tmux sessions/windows (cwd + live branch + foreground cmd)
tmux list-windows -a -F '#{session_name}:#{window_index} [#{pane_current_command}] #{pane_current_path}' 2>/dev/null

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
for d in <dirs from steps 1-2>; do
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
  printf '%-45s [%s] dirty=%s unpushed=%s\n' "$d" "$(git -C "$d" branch --show-current)" \
    "$(git -C "$d" status --porcelain | wc -l)" "$(git -C "$d" log --oneline @{u}.. 2>/dev/null | wc -l)"
done
```

Write the file with these sections (see the template the skill emits):
- **⚠️ Before reboot** — dirty/unpushed repos (commit/stash prompt)
- **🟢 Auto-restarts (enabled --user units)** — do nothing
- **🟡 Manual restart** — running-but-not-enabled services + dev servers (with exact relaunch cmd + port)
- **🔴 Dies on reboot** — tmux/Claude sessions table (session | dir | branch)
- **Docker** — containers w/ vs w/o restart policy; note `mcp/filesystem` are ephemeral (Claude respawns)
- **Resume task** — any in-flight task to pick up (e.g. the original reason for rebooting)

Then: `notes inbox add "reboot restore checklist → $OUT"` and tell the user the path.

Key classification rule: **running ∧ ¬enabled = manual restart**. Enabled units auto-start; don't
list them as action items. Ephemeral `mcp/filesystem` containers are noise — Claude respawns them.

## restore

After reboot:

```bash
ls -t "$(notes path inbox)"/*-reboot-restore.md | head -1      # newest checklist
```

Read it, then **with confirmation** offer to:
- recreate tmux sessions: `tmux new-session -d -s <name> -c <dir>` (+ `tmux send-keys 'claude' Enter` if it was a Claude window)
- start the manual services: `systemctl --user start <unit>`
- relaunch dev servers with the captured command line
- `docker start <name>` for DBs that lacked a restart policy
- surface the dirty repos again so nothing was lost

Never auto-kill or auto-restart without an explicit go-ahead. Confirm the batch, then act.

## Notes

- The skill may use real `date`; in a sandboxed agent context, accept the date as an argument.
- Don't touch auth tokens, sqlite, or other runtime state — this is read-only inventory + opt-in restart.
- Pairs with `wind-down` (single-session teardown). This skill is host-wide: every session at once.
