---
name: monitor-pr
description: "Monitor PR status and CI checks, reporting progress until completion"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch, WebSearch]
---

# PR Monitor

Monitor a GitHub PR's CI status and report progress until all checks complete.

## Instructions

1. **Identify the PR:**
   - If user provides a PR number, use it
   - If user provides a PR URL, extract the number
   - If no PR specified, check the current branch for an associated PR
   - If still no PR, ask the user which PR to monitor

2. **Get initial status:**
   - Use `gh pr checks <number>` to get current check status
   - Report summary: X passing, Y in progress, Z failed, W pending

3. **Monitor loop:**
   - Wait 30 seconds between checks (use `sleep 30`)
   - Re-fetch check status
   - Report any state changes:
     - New failures (show check name and link)
     - New successes
     - New checks started
   - Continue until either:
     - All checks are complete (success, failed, or skipped)
     - User interrupts
     - 30 minutes elapsed (max monitoring time)

4. **Final report:**
   - Summary of all check results
   - List any failed checks with links
   - Overall status: ✅ All passed | ⚠️ Some failed | 🔄 Still running

5. **Output format:**
   ```
   🔍 Monitoring PR #6708: feat(database): unified schema POC

   Initial status:
   ✅ 44 passing
   🔄 3 in progress
   ❌ 2 failed

   [30s] Update:
   ✅ Static Checks completed
   🔄 E2E Tests (1/3) still running

   [60s] Update:
   ❌ E2E Tests (1/3) failed - https://...
   ✅ E2E Tests (2/3) completed

   Final status: ⚠️ Some checks failed
   Failed checks:
   - E2E Tests (1/3): https://...
   - Integration Tests: https://...
   ```

## Usage Examples

```bash
/my:monitor-pr 6708
/my:monitor-pr https://github.com/org/repo/pull/6708
/my:monitor-pr  # monitors current branch's PR
```

## Implementation Notes

- Use `gh pr checks <number> --json name,state,bucket,link`
- State values: SUCCESS, FAILURE, CANCELLED, IN_PROGRESS, PENDING, SKIPPED
- Bucket values: pass, fail, cancel
- Keep track of previous state to detect changes
- Use clear emojis for visual status
- Provide actionable links for failures
