---
name: analysis
description: Run comprehensive repo analysis (security, quality, dependencies) with auto-fixes and Linear tickets
argument-hint: [--dry-run?] [--skip-pr?] [--skip-tickets?]
allowed-tools: mcp__linear__*, mcp__github__*, Bash, Read, Grep, Glob, Write, Edit, Task
---

# Daily Repository Analysis

Comprehensive analysis of the current repository covering security, code quality, and dependencies. Creates PRs for simple fixes and Linear tickets for complex issues.

## Analysis Pipeline

Execute the following analysis phases. For each phase, collect findings into a structured report.

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
# Common secret patterns (API keys, tokens, passwords)
grep -rn --include="*.ts" --include="*.js" --include="*.py" --include="*.go" \
  -E "(api[_-]?key|apikey|secret|password|token|credential).*[=:].*['\"][a-zA-Z0-9]" . \
  | grep -v node_modules | grep -v ".git" | head -20
```

Check for .env files committed:
```bash
git ls-files | grep -E "\.env$|\.env\." | grep -v ".example"
```

#### 2.2 Dependency Vulnerabilities
Run security audit based on project type:

**Node.js**:
```bash
npm audit --json 2>/dev/null || echo '{"vulnerabilities":{}}'
```

**Python**:
```bash
pip-audit --format=json 2>/dev/null || safety check --json 2>/dev/null || echo '[]'
```

**Rust**:
```bash
cargo audit --json 2>/dev/null || echo '{"vulnerabilities":[]}'
```

**Go**:
```bash
govulncheck -json ./... 2>/dev/null || echo '{}'
```

#### 2.3 Security Findings Classification
- **CRITICAL/HIGH**: Create Linear ticket immediately
- **MEDIUM**: Include in report, consider ticket
- **LOW**: Include in report only

---

### Phase 3: Quality Analysis (@quality-engineer mindset)

**Focus**: Lint issues, type errors, code complexity, test coverage

#### 3.1 Lint & Type Check

**Node.js**:
```bash
# Lint with auto-fix capability detection
npx eslint . --format=json 2>/dev/null | head -1000
npx tsc --noEmit 2>&1 | head -50
```

**Python**:
```bash
ruff check . --output-format=json 2>/dev/null | head -1000
mypy . --output=json 2>/dev/null | head -500
```

**Rust**:
```bash
cargo clippy --message-format=json 2>/dev/null | head -500
```

**Go**:
```bash
golangci-lint run --out-format=json 2>/dev/null | head -500
```

#### 3.2 Auto-Fixable Issues
Identify issues that can be auto-fixed:
- ESLint: `--fix` capable rules
- Prettier: formatting issues
- Ruff: `--fix` capable rules
- `cargo fmt`: formatting

#### 3.3 Test Coverage (if available)
```bash
# Check for coverage reports
find . -name "coverage*.json" -o -name "lcov.info" -o -name "coverage.xml" 2>/dev/null | head -5
```

---

### Phase 4: Dependency Analysis (@devops-architect mindset)

**Focus**: Outdated packages, breaking changes, upgrade paths

#### 4.1 Outdated Dependencies

**Node.js**:
```bash
npm outdated --json 2>/dev/null || echo '{}'
```

**Python**:
```bash
pip list --outdated --format=json 2>/dev/null || echo '[]'
```

**Rust**:
```bash
cargo outdated --format=json 2>/dev/null || echo '{"dependencies":[]}'
```

**Go**:
```bash
go list -u -m -json all 2>/dev/null | head -100
```

#### 4.2 Dependency Classification
- **Patch updates**: Safe to auto-update (PR)
- **Minor updates**: Usually safe, review changelog (PR with note)
- **Major updates**: Breaking changes likely (Linear ticket)

---

### Phase 5: Auto-Remediation

Based on `$ARGUMENTS` flags, take action on findings:

#### 5.1 Create Auto-Fix PR (unless --skip-pr)

For simple, low-risk fixes:
1. Create a new branch: `auto-analysis/{date}`
2. Apply auto-fixes:
   - `npm run lint -- --fix` or `npx eslint . --fix`
   - `npx prettier --write .`
   - `ruff check . --fix`
   - `cargo fmt`
3. Commit changes with conventional commit: `fix: auto-fix lint and formatting issues`
4. Create PR using `mcp__github__create_pull_request`:
   - title: "fix: auto-remediation from daily analysis"
   - body: Include summary of fixes applied
   - base: main/master branch

#### 5.2 Create Linear Tickets (unless --skip-tickets)

For complex issues requiring human review, use `mcp__linear__create_issue`:

```
title: "[Auto-Analysis] {category}: {brief description}"
labels: ["auto-analysis", "{severity}", "{category}"]
team: (from LINEAR_TEAM_ID or detect from project)
description: |
  ## Finding
  {detailed description}

  ## Location
  {file paths and line numbers}

  ## Recommended Action
  {remediation steps}

  ## Severity
  {CRITICAL|HIGH|MEDIUM|LOW}
```

Categories:
- `security` - Vulnerabilities, secrets, OWASP issues
- `quality` - Complex lint issues, architectural concerns
- `dependencies` - Major version updates, breaking changes

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
    "tickets_created": [],
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
→ Created: LIN-456 (security vulnerabilities)

✅ QUALITY
───────────────────────────────────────────────────────
Lint Issues: 15 (12 auto-fixed, 3 manual)
Type Errors: 0 ✓
Auto-fixed: 12 issues
→ Created: PR #123 (auto-fix lint issues)

📦 DEPENDENCIES
───────────────────────────────────────────────────────
Outdated: 8 packages
  • 2 major (breaking) → LIN-457
  • 3 minor (safe)
  • 3 patch (auto-updated)
→ Created: PR #124 (patch updates)

📈 SUMMARY
───────────────────────────────────────────────────────
PRs Created: 2 (#123, #124)
Tickets Created: 2 (LIN-456, LIN-457)
Auto-fixes Applied: 12

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Arguments

- `--dry-run`: Run analysis only, no PRs or tickets created
- `--skip-pr`: Skip auto-fix PR creation
- `--skip-tickets`: Skip Linear ticket creation

Parse from `$ARGUMENTS` if provided.

## Notes

- Uses MCP servers for Linear/GitHub - no external API keys needed in command
- Respects `.gitignore` and `node_modules` exclusions
- Caches results to `.claude/cache/` for aggregation
- Can be run headless: `claude --dangerously-skip-permissions -p "/daily:analysis"`
