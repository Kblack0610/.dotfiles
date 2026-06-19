// SessionStart preflight for OpenCode — parity with Claude Code's SessionStart hook.
//
// Claude Code runs ~/.config/shared-hooks/session-preflight.sh on session start and
// injects its `additionalContext` (project anchor + active plans + recent lessons +
// git/PR state) into turn 1. OpenCode has no SessionStart hook, so this plugin reuses
// the SAME shell script (single source of truth) and appends its output as a synthetic
// text part on the first user message of each session — which persists in history, the
// closest analog to Claude's additionalContext.
//
// Light by design: only the preflight is ported. The stop-hook plan-sync, eval gate,
// and llm-judge remain Claude-Code-only.
//
// Auto-discovered from ~/.config/opencode/plugins/ (a stow symlink into the dotfiles
// repo), so it propagates to other machines via `git pull`. opencode.json is untouched.

import type { Plugin } from "@opencode-ai/plugin"

const PREFLIGHT = `${process.env.HOME}/.config/shared-hooks/session-preflight.sh`

// Sessions already seeded this process — inject exactly once per session.
const seeded = new Set<string>()

const plugin: Plugin = async ({ directory, $ }) => ({
  "chat.message": async (_input, output) => {
    const sessionID = output.message.sessionID
    if (!sessionID || seeded.has(sessionID)) return
    seeded.add(sessionID)

    // Run the shared preflight script and pull out its additionalContext. The script
    // emits Claude-hook JSON: {hookSpecificOutput:{additionalContext:"..."}}. Fail soft
    // on any error (missing script, bad JSON, non-git dir) — inject nothing.
    let ctx = ""
    try {
      const result = await $`bash ${PREFLIGHT}`
        .env({ ...process.env, CLAUDE_PROJECT_DIR: directory })
        .quiet()
        .nothrow()
        .json()
      ctx = result?.hookSpecificOutput?.additionalContext ?? ""
    } catch {
      return
    }
    if (!ctx.trim()) return

    output.parts.push({
      id: `prt_preflight_${sessionID}`,
      sessionID,
      messageID: output.message.id,
      type: "text",
      text: ctx,
      synthetic: true,
    })
  },
})

export default plugin
