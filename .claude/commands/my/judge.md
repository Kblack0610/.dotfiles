---
name: judge
description: "LLM Judge — evaluate this session against shared AI rules"
allowed-tools: [Bash, Read, Glob]
---

# LLM Judge — Session Compliance Check

Evaluate this session against the shared AI assistant rules using an LLM-as-judge.

## Steps

### 1. Find the session transcript

Look for the current session's JSONL transcript file. Claude Code stores transcripts in `~/.claude/projects/`. The transcript for this session can be found by checking:

```bash
# List recent transcripts, find the one being actively written (largest/newest)
ls -lt ~/.claude/projects/*/  2>/dev/null | head -20
```

Look for `.jsonl` files. The current session's transcript will be the most recently modified one in the project directory matching this working directory.

### 2. Run the judge

```bash
bash ~/.dotfiles/.claude/hooks/llm-judge.sh <transcript_path>
```

### 3. Report results

Present the verdict to the user:
- If **pass**: briefly confirm compliance
- If **warn**: list the warnings with the judge's suggestions
- If **fail/block**: highlight the violations clearly, explain what should have been done differently

If the judge script fails (LLM unreachable, etc.), tell the user what went wrong. Do not retry — the script handles its own fallback chain.
