---
name: analysis
description: Run comprehensive repo analysis (security, quality, dependencies) with auto-fixes; logs findings to notes inbox; optional GitHub issue creation
argument-hint: [--dry-run?] [--skip-pr?] [--github-issues?]
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Task
---

# Daily Repository Analysis

Comprehensive analysis of the current repository covering security, code
quality, and dependencies. Creates auto-fix PRs for simple fixes; logs
complex findings to `~/.notes/inbox/<date>-analysis.md`. Optionally
creates GitHub issues with `--github-issues`.

Sources: shell tooling + `gh` CLI (`gh-workflows` skill). Linear is no
longer used; GitHub MCP is intentionally NOT used (project preference:
`gh` CLI over MCP).

## Analysis Pipeline

Execute the following analysis phases. For each phase, collect findings
into a structured report.

### Phase 1: Project Detection

Detect the project type and available tooling:

```bash
# Detect project type
if [[ -f "package.json" ]]; then PROJECT_TYPE="node"; fi
if [[ -f "Cargo.toml" ]]; then PROJECT_TYPE="rust"; fi
if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then PROJECT_TYPE="python"; fi
if [[ -f "go.mod" ]]; then PROJECT_TYPE="go"; fi
```

Store detected type for subsequent phases.

---

### Phase 2: Security Analysis (@security-engineer mindset)

**Focus**: OWASP Top 10, secrets detection, dependency vulnerabilities

#### 2.1 Secrets Scan
Search for hardcoded secrets and credentials:
```bash
grep -rn --include="*.ts" --include="*.js" --include="*.py" --include="*.go" \
  -E "(api[_-]?key|apikey|secret|password|token|credential).*[=:].*['\"][a-zA-Z0-9]" . \
  | grep -v node_modules | grep -v ".git" | head -20
```

Check for .env files committed:
```bash
git ls-files | grep -E "\.env$|\.env\." | grep -v ".example"
```

#### 2.2 Dependency Vulnerabilities

**Node.js**: `npm audit --json 2>/dev/null || echo '{"vulnerabilities":{}}'`
**Python**: `pip-audit --format=json 2>/dev/null || safety check --json 2>/dev/null || echo '[]'`
**Rust**: `cargo audit --json 2>/dev/null || echo '{"vulnerabilities":[]}'`
**Go**: `govulncheck -json ./... 2>/dev/null || echo '{}'`

#### 2.3 Security Findings Classification
- **CRITICAL/HIGH**: log to `~/.notes/inbox/<date>-analysis.md` immediately; if `--github-issues`, also create a GitHub issue
- **MEDIUM**: include in report + notes inbox
- **LOW**: include in report only

---

### Phase 3: Quality Analysis (@quality-engineer mindset)

**Focus**: lint issues, type errors, code complexity, test coverage

#### 3.1 Lint & Type Check

**Node.js**:
```bash
npx eslint . --format=json 2>/dev/null | head -1000
npx tsc --noEmit 2>&1 | head -50
```

**Python**:
```bash
ruff check . --output-format=json 2>/dev/null | head -1000
mypy . --output=json 2>/dev/null | head -500
```

**Rust**: `cargo clippy --message-format=json 2>/dev/null | head -500`
**Go**: `golangci-lint run --out-format=json 2>/dev/null | head -500`

#### 3.2 Auto-Fixable Issues

Identify issues that can be auto-fixed:
- ESLint: `--fix` capable rules
- Prettier / `cargo fmt` / `gofmt`: formatting
- Ruff: `--fix` capable rules

#### 3.3 Test Coverage (if available)

```bash
find . -name "coverage*.json" -o -name "lcov.info" -o -name "coverage.xml" 2>/dev/null | head -5
```

---

### Phase 4: Dependency Analysis (@devops-architect mindset)

**Focus**: outdated packages, breaking changes, upgrade paths

#### 4.1 Outdated Dependencies

**Node.js**: `npm outdated --json 2>/dev/null || echo '{}'`
**Python**: `pip list --outdated --format=json 2>/dev/null || echo '[]'`
**Rust**: `cargo outdated --format=json 2>/dev/null || echo '{"dependencies":[]}'`
**Go**: `go list -u -m -json all 2>/dev/null | head -100`

#### 4.2 Dependency Classification
- **Patch updates**: safe to auto-update (PR)
- **Minor updates**: usually safe, review changelog (PR with note)
- **Major updates**: breaking changes likely (notes inbox writeup)

---

### Phase 5: Auto-Remediation

Based on `$ARGUMENTS` flags, take action on findings:

#### 5.1 Create Auto-Fix PR (unless --skip-pr or --dry-run)

For simple, low-risk fixes:
1. Create a new branch: `auto-analysis/{date}`
2. Apply auto-fixes:
   - `npm run lint -- --fix` or `npx eslint . --fix`
   - `npx prettier --write .`
   - `ruff check . --fix`
   - `cargo fmt`
3. Commit with conventional format: `fix: auto-fix lint and formatting issues`
4. Create PR via `gh pr create`:
   ```bash
   gh pr create \
     --title "fix: auto-remediation from daily analysis ($(date +%Y-%m-%d))" \
     --body "$(cat <<'EOF'
## Summary
Automated fixes applied:
- {list}

## Test Plan
- CI must pass
- Spot-check formatting changes
EOF
)" \
     --base main
   ```

#### 5.2 Log Findings to Notes Inbox (always)

For complex findings (HIGH/CRITICAL security, MEDIUM+ quality, MAJOR deps),
append a structured markdown section to `~/.notes/inbox/<date>-analysis.md`:

```bash
INBOX_FILE="$HOME/.notes/inbox/$(date +%Y-%m-%d)-analysis.md"
mkdir -p "$(dirname "$INBOX_FILE")"
cat >> "$INBOX_FILE" <<EOF
## $(date +%H:%M) — $REPO_NAME analysis findings

### {category}: {brief description}

**Location**: {file paths and line numbers}

**Severity**: {CRITICAL|HIGH|MEDIUM|LOW}

**Recommended Action**: {remediation steps}

EOF
```

This is the system of record. The notes inbox is auto-synced and durable.

#### 5.3 Optional: Create GitHub Issues (if --github-issues passed)

For each complex finding, when `--github-issues` is in `$ARGUMENTS`:

```bash
gh issue create \
  --title "[Auto-Analysis] {category}: {brief description}" \
  --label "auto-analysis,{severity},{category}" \
  --body "$(cat <<EOF
## Finding
{detailed description}

## Location
{file paths and line numbers}

## Recommended Action
{remediation steps}

## Severity
{CRITICAL|HIGH|MEDIUM|LOW}

_Generated by /daily:analysis on $(date +%Y-%m-%d)_
EOF
)"
```

Off by default to avoid accidental issue spam.

Categories:
- `security` — vulnerabilities, secrets, OWASP issues
- `quality` — complex lint issues, architectural concerns
- `dependencies` — major version updates, breaking changes

---

### Phase 6: Generate Report

Output structured JSON summary (also save to `.claude/cache/analysis-{date}.json`):

```json
{
  "repo": "{current repo name}",
  "analyzed_at": "{ISO-8601 timestamp}",
  "project_type": "{node|python|rust|go}",
  "security": {
    "secrets_found": 0,
    "vulnerabilities": {
      "critical": 0,
      "high": 0,
      "medium": 0,
      "low": 0
    },
    "findings": []
  },
  "quality": {
    "lint_errors": 0,
    "lint_warnings": 0,
    "type_errors": 0,
    "auto_fixable": 0,
    "findings": []
  },
  "dependencies": {
    "outdated_total": 0,
    "major_updates": 0,
    "minor_updates": 0,
    "patch_updates": 0,
    "security_advisories": 0,
    "findings": []
  },
  "actions_taken": {
    "pr_created": null,
    "github_issues_created": [],
    "notes_inbox_path": "/path/to/<date>-analysis.md",
    "auto_fixes_applied": 0
  }
}
```

---

## Output Format

Present a clean summary to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 REPOSITORY ANALYSIS - {repo} - {date}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔒 SECURITY
───────────────────────────────────────────────────────
Vulnerabilities: 2 (1 HIGH, 1 MEDIUM)
  • HIGH: lodash prototype pollution (CVE-2021-xxxx)
  • MEDIUM: minimist < 1.2.6
Secrets Found: 0 ✓

✅ QUALITY
───────────────────────────────────────────────────────
Lint Issues: 15 (12 auto-fixed, 3 manual)
Type Errors: 0 ✓
Auto-fixed: 12 issues
→ Created: PR #123 (auto-fix lint issues)

📦 DEPENDENCIES
───────────────────────────────────────────────────────
Outdated: 8 packages
  • 2 major (breaking)
  • 3 minor (safe)
  • 3 patch (auto-updated)
→ Created: PR #124 (patch updates)

📈 SUMMARY
───────────────────────────────────────────────────────
PRs Created: 2 (#123, #124)
Findings logged to: ~/.notes/inbox/{date}-analysis.md
GitHub Issues: 0 (pass --github-issues to create)
Auto-fixes Applied: 12

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Arguments

- `--dry-run`: Run analysis only, no PRs / issues / notes writes
- `--skip-pr`: Skip auto-fix PR creation (still logs to notes)
- `--github-issues`: Also create a GitHub issue per complex finding (off by default)

Parse from `$ARGUMENTS` if provided.

## Notes

- Uses `gh` CLI (per `gh-workflows` skill) — no GitHub MCP tools
- Auth from `gh auth login` state, not MCP server config
- Findings ALWAYS go to `~/.notes/inbox/<date>-analysis.md` (system of record)
- GitHub issues are opt-in via `--github-issues` to avoid issue spam
- Caches results to `.claude/cache/` for aggregation
- Can run headless: `claude --dangerously-skip-permissions -p "/daily:analysis"`
