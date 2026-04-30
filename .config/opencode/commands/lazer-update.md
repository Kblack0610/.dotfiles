---
description: Review and apply Lazer updater changes safely
agent: lazer-updater
subtask: true
model: lazer/gpt-5.4
---
Review this system for updater changes and guide me through a safe update.

Requested flags/arguments: $ARGUMENTS

Workflow:
1. Run a dry run first and summarize what would change.
2. Call out what local customizations will be preserved.
3. Ask me for confirmation before applying.
4. If I approve, run the real update command.
