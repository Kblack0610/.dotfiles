---
name: bitbucket-ops
description: Bitbucket Cloud operations via the bitbucket CLI — pull requests, pipelines, issues, and code search. Use when the user asks to interact with Bitbucket (review/create PRs, check pipelines, browse issues, search code). Enterprise-safe: defaults to read-only; confirms before visible writes or any destructive action.
---

# bitbucket-ops

Drive Bitbucket Cloud through the `bitbucket` Rust CLI (v0.3.18, crate `bitbucket-cli`).
Binary: `/root/.cargo/bin/bitbucket`. Authenticated separately per workspace via `bitbucket auth login`.

Default workspace for TechData/Deloitte: `techdataassets`. Override per command with `-w <workspace>`.

## Prerequisites

```bash
# Verify the binary is on PATH
bitbucket --version   # expect: bitbucket 0.3.18

# Check auth status for the active workspace (happy path: already authenticated)
bitbucket auth status   # expect: ✓ Authenticated
```

### Auth on WSL — happy path (zero prompts)

This machine is already set up for **headless** use: a new WSL shell auto-unlocks the
keyring via `.zshrc`, and `bitbucket auth status` returns `✓ Authenticated` with no GUI
and no typing. If you just need to *use* the CLI, do nothing — it works.

Key facts (full detail + rebuild/troubleshooting in **[wsl-headless-auth.md](./wsl-headless-auth.md)**):

- **API token only.** App passwords are deprecated (removed 2026-07-28). Create an API
  token with scopes; username = your **Atlassian account email** (not the Bitbucket handle).
- **Creds live in the keyring**, not env/files. The CLI has no env/file credential fallback.
- **WSL keyring unlock** is handled by a block in `~/.dotfiles/.zshrc` (the `~/.zshrc`
  symlink target). gnome-keyring starts locked even with an empty password, so it's
  unlocked once per session automatically.
- **Re-login (rare):** `bitbucket auth login --api-key -w techdataassets` — TTY prompt for
  email + token. `--oauth` opens a browser (do NOT use on WSL). See runbook for non-
  interactive/CI login via a pseudo-tty.

```bash
# Re-authenticate only if `auth status` is NOT ✓ (e.g. token rotated/expired)
bitbucket auth login --api-key -w techdataassets   # username = Atlassian email; paste token
```

Repo addressing is always `workspace/repo-slug` (e.g. `techdataassets/my-service`).
When inside a cloned Bitbucket repo, the CLI can auto-detect `-w` and `-r` from the git remote.

## Pull requests

```bash
# List open PRs (default limit 25)
bitbucket pr list workspace/repo-slug
bitbucket pr list workspace/repo-slug --state open --limit 50
bitbucket pr list workspace/repo-slug --state merged
bitbucket pr list workspace/repo-slug --state declined

# View PR details
bitbucket pr view workspace/repo-slug 123
bitbucket pr view workspace/repo-slug 123 --web   # open in browser

# Read the diff
bitbucket pr diff workspace/repo-slug 123

# Read review comments (full thread)
bitbucket pr list-comments workspace/repo-slug 123
bitbucket pr list-comments workspace/repo-slug 123 --limit 50

# View a specific comment
bitbucket pr view-comment workspace/repo-slug 123 <comment-id>

# Check CI pipelines for the PR's head commit
bitbucket pr pipelines workspace/repo-slug 123

# Check out a PR branch locally
bitbucket pr checkout workspace/repo-slug 123

# Create a PR — pass body via $() + heredoc for multi-line descriptions
bitbucket pr create workspace/repo-slug \
  --title "Short title under 72 chars" \
  --source feature/my-branch \
  --destination main \
  --body "$(cat <<'EOF'
## Summary
- bullet one
- bullet two

## Test plan
- [ ] step one
- [ ] step two
EOF
)"

# Add a comment to a PR (confirm with user first — visible to the team)
bitbucket pr comment workspace/repo-slug 123 --body "LGTM, one nit inline."

# Approve a PR (confirm with user first — triggers notification)
bitbucket pr approve workspace/repo-slug 123
```

**Gated operations** — always confirm with the user before running:

```bash
# Merge a PR
bitbucket pr merge workspace/repo-slug 123 --strategy squash --close-source-branch
bitbucket pr merge workspace/repo-slug 123 --strategy merge-commit --message "Merge PR #123"
bitbucket pr merge workspace/repo-slug 123 --strategy fast-forward

# Decline a PR
bitbucket pr decline workspace/repo-slug 123
```

## Pipelines / CI

```bash
# List recent pipeline runs (read-only — always safe)
bitbucket pipeline list workspace/repo-slug
bitbucket pipeline list workspace/repo-slug --limit 10

# View pipeline details
bitbucket pipeline view workspace/repo-slug --build 42

# View step logs (can be verbose — pipe to less)
bitbucket pipeline view workspace/repo-slug --build 42 --logs | less
```

**Gated operations** — always confirm with the user before running:

```bash
# Trigger a new pipeline build
bitbucket pipeline trigger workspace/repo-slug

# Stop a running pipeline
bitbucket pipeline stop workspace/repo-slug --build 42
```

## Issues

```bash
# List issues
bitbucket issue list workspace/repo-slug
bitbucket issue list workspace/repo-slug --state open
bitbucket issue list workspace/repo-slug --state resolved --limit 20
# Valid states: new, open, resolved, on-hold, invalid, duplicate, wontfix, closed

# View an issue
bitbucket issue view workspace/repo-slug 7
bitbucket issue view workspace/repo-slug 7 --web   # open in browser

# Create an issue
bitbucket issue create workspace/repo-slug \
  --title "Descriptive title" \
  --body "Steps to reproduce..." \
  --kind bug \
  --priority major
# kinds: bug, enhancement, proposal, task
# priorities: trivial, minor, major, critical, blocker

# Comment on an issue
bitbucket issue comment workspace/repo-slug 7 --body "Reproduced on v1.2.3."
```

**Gated operations** — confirm with the user before running:

```bash
# Close / reopen an issue
bitbucket issue close workspace/repo-slug 7
bitbucket issue reopen workspace/repo-slug 7
```

## Code search (REST API fallback)

The `bitbucket` CLI does not expose a `search` subcommand. Use the Bitbucket REST API v2 directly:

```bash
# Requires a Bitbucket app password or OAuth token
BB_TOKEN="<app-password-or-oauth-token>"
BB_WORKSPACE="techdataassets"

# Search code across all repos in a workspace
curl -s -u "username:$BB_TOKEN" \
  "https://api.bitbucket.org/2.0/search/code?search_query=<term>&workspace=$BB_WORKSPACE" \
  | jq '.values[] | {path: .file.path, repo: .file.commit.repository.full_name, lines: .content_matches}'

# Search within a specific repo
curl -s -u "username:$BB_TOKEN" \
  "https://api.bitbucket.org/2.0/search/code?search_query=<term>&workspace=$BB_WORKSPACE" \
  | jq '.values[] | select(.file.commit.repository.slug == "my-service")'

# Paginate (default page length 10, max 100)
curl -s -u "username:$BB_TOKEN" \
  "https://api.bitbucket.org/2.0/search/code?search_query=<term>&workspace=$BB_WORKSPACE&pagelen=50&page=2" \
  | jq '.values[].file.path'
```

Note: Bitbucket Cloud code search requires the workspace to have the feature enabled. Results may be incomplete for very large repos.

## Safety rules

These rules apply in enterprise contexts (e.g. `techdataassets`) where actions are visible to clients and colleagues:

1. **Default read-only.** `list`, `view`, `diff`, `list-comments`, `pipelines` are always safe to run without asking.
2. **Confirm before visible writes.** `pr comment`, `pr approve`, `issue comment`, `issue create` notify other users — confirm with the user unless explicitly requested.
3. **Gate merges and declines.** Never run `pr merge` or `pr decline` without explicit user instruction. Prefer squash strategy unless the user specifies otherwise.
4. **Gate pipeline execution.** Never run `pipeline trigger` or `pipeline stop` without explicit user instruction. In enterprise CI, a spurious trigger can consume quota or break a deploy.
5. **No destructive repo ops.** Never run `repo delete` or document `repo fork` in automation unless the user explicitly asks. `repo create` requires explicit instruction.
6. **No auth mutations.** Never run `bitbucket auth logout` without user confirmation — it requires re-authentication, which may require admin access in SSO environments.
7. **TUI is interactive only.** `bitbucket tui` launches an interactive terminal UI — useful for the user to run manually, not for scripted automation.

## Quick reference

| What | Command |
|---|---|
| Check auth | `bitbucket auth status` |
| List open PRs | `bitbucket pr list workspace/repo` |
| View PR | `bitbucket pr view workspace/repo <id>` |
| Read PR diff | `bitbucket pr diff workspace/repo <id>` |
| Read PR comments | `bitbucket pr list-comments workspace/repo <id>` |
| PR CI status | `bitbucket pr pipelines workspace/repo <id>` |
| Create PR | `bitbucket pr create workspace/repo --title "..." --source branch --body "..."` |
| List pipelines | `bitbucket pipeline list workspace/repo` |
| View pipeline logs | `bitbucket pipeline view workspace/repo --build N --logs` |
| List issues | `bitbucket issue list workspace/repo` |
| Create issue | `bitbucket issue create workspace/repo --title "..." --kind bug` |
| Code search | REST API: `curl ... api.bitbucket.org/2.0/search/code?search_query=<term>&workspace=...` |
| Default workspace | `techdataassets` (override with `-w <workspace>`) |
| CLI docs | `bitbucket <command> --help` |
