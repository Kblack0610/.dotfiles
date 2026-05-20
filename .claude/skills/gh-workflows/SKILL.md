---
name: gh-workflows
description: GitHub operations via the gh CLI — pull requests, issues, CI checks, workflow runs, releases, and repo management. Use whenever the user asks to interact with GitHub (create/view PRs, check CI, browse issues, run workflows, etc.). Prefer this over any GitHub MCP.
---

# gh-workflows

Drive GitHub through the `gh` CLI via Bash. No MCP wrapper needed — `gh` is authenticated on this machine and covers the full GitHub surface.

## Pull requests

```bash
# List recent PRs
gh pr list -L 10
gh pr list --state all --author @me

# View a PR (diff, checks, comments)
gh pr view <number>
gh pr view <number> --json state,statusCheckRollup,reviewDecision
gh pr diff <number>
gh pr checks <number>

# Create a PR — always pass body via HEREDOC for multi-line content
gh pr create --title "short title under 70 chars" --body "$(cat <<'EOF'
## Summary
- bullet one
- bullet two

## Test plan
- [ ] step one
- [ ] step two
EOF
)"

# Comment, merge, close
gh pr comment <number> --body "..."
gh pr merge <number> --squash --delete-branch
gh pr close <number>
```

## Issues

```bash
gh issue list -L 20
gh issue list --label bug --state open
gh issue view <number>
gh issue view <number> --comments
gh issue create --title "..." --body "..." --label bug
gh issue comment <number> --body "..."
gh issue close <number>
gh issue edit <number> --add-label triage
```

## CI / Actions

```bash
gh run list -L 10
gh run list --workflow=ci.yml --branch=main
gh run view <run-id>
gh run view <run-id> --log-failed
gh run watch <run-id>              # stream until finished
gh run cancel <run-id>
gh run rerun <run-id> --failed

gh workflow list
gh workflow run <workflow.yml> -f key=value
```

## Search

```bash
gh search prs "bug label:regression" --repo owner/name
gh search issues "is:open author:@me"
gh search code "func foo" --language=go
```

## Anything else: `gh api`

`gh api` handles everything not covered by a first-class command. It automatically uses the authenticated session and supports pagination.

```bash
gh api repos/owner/name/pulls/123/comments
gh api repos/owner/name/commits --jq '.[].sha'
gh api graphql -f query='query { viewer { login } }'
gh api --paginate repos/owner/name/issues
```

## Safety rules

- Never use `--no-verify`, `--no-gpg-sign`, or similar hook-bypass flags unless the user explicitly asks.
- Never force-push to `main` / `master`. Warn the user if they request it.
- Prefer creating new commits over `git commit --amend` when a pre-commit hook fails — the failed commit did not happen, so `--amend` would modify the previous commit.
- Before commenting on a PR or closing an issue, confirm with the user unless the action was explicitly requested — these are visible to others.
- For destructive ops (force-push, branch delete, release delete), confirm first.

## Tips

- Use `--json <fields> --jq '<expr>'` for scripting instead of parsing human output.
- `gh repo view --web` opens the repo in a browser; `--json` for structured data.
- For checking CI state on the current branch: `gh pr checks` (no number needed when on a PR branch).
