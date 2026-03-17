# LLM Judge — Session Compliance Check

Evaluate this session against the shared AI assistant rules.

## How to Use

When the user invokes `/llm-judge`, follow these steps:

### 1. Summarize the session

Since Codex does not expose transcript files, you must self-summarize the session. Produce a structured summary covering:

- **Task**: What was the user's request?
- **Actions taken**: What did you do? (list each major step)
- **Tools used**: Which tools/commands were executed?
- **Files changed**: Which files were created, modified, or deleted?
- **Verification performed**: Did you verify the result? How?
- **User corrections**: Did the user correct you at any point? What was the correction?
- **Infrastructure context**: Were any infrastructure/deployment questions involved? Did you identify the target environment?

### 2. Run the judge

Pipe your summary to the judge script:

```bash
bash ~/.dotfiles/.config/codex/skills/llm-judge/judge.sh
```

The summary should be piped via stdin.

### 3. Report results

Present the verdict to the user with any violations highlighted. If the judge fails, explain the error — do not retry.
