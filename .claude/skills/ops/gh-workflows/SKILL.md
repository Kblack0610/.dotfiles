---
name: gh-workflows
description: GitHub operations via the gh CLI - pull requests, issues, CI checks, workflow runs, releases, and repo management. Use whenever the user asks to interact with GitHub (create/view PRs, check CI, browse issues, run workflows, etc.). Prefer this over any GitHub MCP.
metadata:
  category: ops
  tags: [git, github, pull-requests, ci]
  system: [ci]
  reviewed: "2026-11-22"
  replaces:
    - match: '(?:^|[;&|(){}\s])gh\s+run\s+watch(?=[;&|(){}\s]|$)'
      use: "a PR: `agent-land <N>` waits for its checks (foreground with `timeout: 600000` when the gate and checks run under 10 minutes; a long gate such as unity-core-playground's: run_in_background). Any other run: `gh-run-wait <run-id> [label]` (foreground with `timeout: 600000` when it runs under 10 minutes, else run_in_background); do not write your own waiter"
      mode: deny
      why: gh run watch polls the GitHub API for the whole wait and blocks the turn (337 playground sessions tried it in 30 days to 2026-11-09)
    - match: '(?:^|[;&|(){}\s/])gh\s+(?:run\s+rerun(?![\w-])|api\s(?:[^;&|\n]*actions/(?:runs|jobs)/[^/\s]+/rerun(?:-failed-jobs)?(?![\w-])|\s*Q\s[^;&|\n]*(?:-X\s+|--method[\s=]+)(?i:POST)(?![\w-])|[^;&|\n]*(?:-X\s+|--method[\s=]+)(?i:POST)\s+Q\s))'
      use: "diagnose the red first (`fix-ci`; a runner slot fault across runs: `ci-cleanup`). Rerun only for an infra fault the log names (runner lost, registry 5xx, rate limit), once per PR tip, and name it on the command: `gh run rerun <id> --failed  # infra: <fault>`"
      mode: deny
      unless: '#\s*infra:\s*[A-Za-z]'
      why: "a blind rerun hides a real red or a broken runner slot (PR #2095 reran twice on a slot missing its job-end hook, 2026-11-18)"
    - match: '(?:^|[;&|(){}\s/])gh(?:\s+(?:-R|--repo)[\s=]\S+)*\s+(?:run\s+cancel(?![\w-])|api\s(?:[^;&|\n]*actions/runs/[^/\s]+/(?:force-)?cancel(?![\w-])))'
      use: "a lander never cancels another PR's run to jump the runner queue: queue order is the pool's job (ci.md). Cancel only a superseded run of your own PR (`# own: <pr>`) or a hung job whose live step you read (`# stuck: <step>`), and say which on the command: `gh run cancel <id>  # own: #<N> superseded`"
      mode: deny
      unless: '#\s*(?:own|stuck):\s*[A-Za-z0-9#]'
      why: "the #2526 session cancelled 19 other PRs' runs in two rounds on 2026-11-18 (#2530 twice), their landers re-pushed and the pool churned (ar-3299)"
---

# gh-workflows

Drive GitHub through the `gh` CLI via Bash. No MCP wrapper needed - `gh` is authenticated on this machine and covers the full GitHub surface.

## Scope and triggers

Covers GitHub operations through the `gh` CLI: pull requests, issues, CI checks, workflow runs, releases and repo management.

Use whenever the user asks to interact with GitHub. Prefer this over any GitHub MCP. A pile of open PRs: `ingest-prs`.

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

# Create a PR - always pass body via HEREDOC for multi-line content
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
agent-land <number>   # merge: never gh pr merge, which forge-guard denies; agent-land records the PR on its queue item
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
gh-run-wait <run-id> [label]          # wait on the run (foreground with timeout: 600000 under 10 min, else in the background); exit code is its result (gh run watch is denied: this skill's metadata.replaces)
gh pr checks <number> --watch --fail-fast
gh run cancel <run-id>  # own: #<N> superseded   (only your own PR's run, or `# stuck: <live step>`; another PR's run never)

gh workflow list
gh workflow run <workflow.yml> -f key=value
```

Wait on a run with `--watch` / `--exit-status`, never a sleep loop. A red check is diagnosed, not rerun: diff `--log-failed` against the last green run of the same workflow. `gh run rerun <run-id> --failed` (or `gh api .../rerun`) is only for an infra fault the log names (runner lost, registry 5xx, rate limit), once per PR tip, and the command carries `# infra: <fault>` or the hook denies it; a test failure is never rerun. Fixing reds: `fix-ci`; red patterns across many runs: `ci-cleanup`. Landing a gated PR and recording it: `agent-land`.

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

- Never use `--no-gpg-sign` or a similar bypass flag unless the user explicitly asks. `skip-guard` denies `--no-verify` and a direct push to a default branch even when the user asks: the user runs that command by hand.
- Never force push: not `--force`, not `--force-with-lease`, on any branch, and do not offer it as an option. If a branch's pushed history is wrong, open a new branch and a new PR and close the old one.
- Prefer creating new commits over `git commit --amend` when a pre-commit hook fails - the failed commit did not happen, so `--amend` would modify the previous commit.
- Before commenting on a PR or closing an issue, confirm with the user unless the action was explicitly requested - these are visible to others.
- For destructive ops (branch delete, release delete), confirm first.
- Pushing a branch, opening a PR, and merging your own green PR are none of the above - they are covered by the Landing rule in `CLAUDE.md` and need no confirmation. Do not invent a gate for them here.

## Tips

- Use `--json <fields> --jq '<expr>'` for scripting instead of parsing human output.
- `gh repo view --web` opens the repo in a browser; `--json` for structured data.
- For checking CI state on the current branch: `gh pr checks` (no number needed when on a PR branch).
