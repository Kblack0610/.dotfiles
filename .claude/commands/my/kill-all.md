---
name: kill-all
description: "Kill all processes running for this project for manual testing"
allowed-tools: [Bash, Read, Grep]
---

Kill all processes running for this project so the user can manually test the application.

## Steps

1. **Find project processes** - Look for common development processes:
   - Node.js processes (npm, pnpm, yarn, node)
   - Vite/webpack dev servers
   - TypeScript watchers (tsc --watch)
   - Test runners (vitest, jest)
   - Any process with the project directory in its path

2. **List before killing** - Show the user what processes will be killed

3. **Kill processes** - Use appropriate signals:
   - Start with SIGTERM for graceful shutdown
   - Use SIGKILL if processes don't terminate

4. **Verify** - Confirm all processes have been terminated

## Common patterns to look for

```bash
# Find processes by current directory name
pgrep -f "$(basename $(pwd))"

# Find node processes
pgrep -f "node.*$(basename $(pwd))"

# Find processes on common dev ports (3000, 4173, 5173, 8080)
lsof -i :3000 -i :4173 -i :5173 -i :8080 2>/dev/null
```

## Safety

- Never kill system processes
- Show what will be killed before doing it
- Skip processes that don't belong to the current user
