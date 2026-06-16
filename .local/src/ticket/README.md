# `ticket` — system-agnostic ticket CLI

A small CLI that lets the kb workflow create/claim tickets without hard-coding a
provider. Backends (vikunja, jira, clickup, linear, notion, local, none) are
selected per-repo via `project-map.json` → `trackers`.

```
ticket [--dry-run] system
ticket [--dry-run] resolve-epic <shorthand>
ticket [--dry-run] claim <id>
ticket [--dry-run] create <epic> <title> [--labels=a,b,...]
ticket [--dry-run] done <id>
ticket [--dry-run] pr-line <id>
```

This CLI is the **mechanical fallback** (token + curl). The preferred path is
MCP-driven: when a system's MCP is connected the kb agent drives it directly per
`docs/adapters/<system>.md`. Both honor the same verbs and PR-line format.

**Full contract, both write modes, label vocabulary, resolution order, per-system
MCP adapters, and config templates:** `docs/contract.md` (+ `docs/adapters/`).

## Layout

```
ticket              entrypoint: flags, repo-local override, backend dispatch
lib/common.sh       die/warn, cfg(), resolve_token(), http() (+ --dry-run)
lib/config.sh       resolve project name -> trackers.<name> | trackers.default
backends/<sys>.sh   one file per system; each exposes tb_<verb> functions
```

## Add a backend

Create `backends/<sys>.sh` exposing `tb_system` is implicit (the entrypoint
prints `$TICKET_SYSTEM`); implement `tb_resolve_epic`, `tb_claim`, `tb_create`,
`tb_done`, `tb_pr_line`. Use `cfg '.field'` to read config, `resolve_token` for
auth, and `http METHOD URL [body] -H ...` so `--dry-run` works for free. Then add
a `trackers.<project>` block with `"system":"<sys>"`.

## Verify safely

```bash
ticket --dry-run create 24 "test(ci): wiring" --labels=ci,P2   # prints calls, no writes
ticket system          # active backend for cwd
ticket pr-line 213     # exact PR-body line
```
