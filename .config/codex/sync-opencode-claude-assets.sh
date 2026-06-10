#!/bin/bash
# Mirror Claude Code agents + commands into OpenCode's global config.
#
# OpenCode (>=1.x) natively reads ~/.claude/CLAUDE.md (rules) and
# ~/.claude/skills/ (skills), but has NO compat path for ~/.claude/agents
# or ~/.claude/commands. This script converts those into
# ~/.config/opencode/agents/ and ~/.config/opencode/commands/.
#
# Conversion rules (derived from opencode source, packages/opencode/src/config):
#  - agents:   frontmatter is sanitized to {description, mode: subagent}.
#              Claude's `tools: "Read, Grep"` string would fail OpenCode's
#              Record<string,boolean> schema, and `name:` overrides the
#              filename-derived agent name — both are dropped.
#  - commands: frontmatter is sanitized to {description}. A `name:` key would
#              override the path-derived name and collapse namespaced commands
#              (kb/implement.md -> "implement") into collisions — dropped.
#              Subdirectories are preserved: Claude's /kb:implement becomes
#              OpenCode's /kb/implement.
#
# Generated files are tracked in a manifest so re-runs clean up renames/removals
# without touching natively-authored OpenCode agents/commands.
set -euo pipefail

CLAUDE_SRC="${CLAUDE_SRC:-$HOME/.dotfiles/.claude}"
OPENCODE_HOME="${OPENCODE_HOME:-$HOME/.config/opencode}"
MANIFEST="$OPENCODE_HOME/.claude-assets-manifest"

if [ ! -d "$CLAUDE_SRC" ]; then
    echo "Missing Claude source directory: $CLAUDE_SRC" >&2
    exit 1
fi

mkdir -p "$OPENCODE_HOME/agents" "$OPENCODE_HOME/commands"

# Remove previously generated files (manifest-tracked) so renames don't leave strays.
if [ -f "$MANIFEST" ]; then
    while IFS= read -r rel; do
        [ -n "$rel" ] && rm -f "$OPENCODE_HOME/$rel"
    done < "$MANIFEST"
fi

CLAUDE_SRC="$CLAUDE_SRC" OPENCODE_HOME="$OPENCODE_HOME" MANIFEST="$MANIFEST" python3 - <<'PYEOF'
import os, sys, pathlib, yaml

src = pathlib.Path(os.environ["CLAUDE_SRC"])
dst = pathlib.Path(os.environ["OPENCODE_HOME"])
manifest_path = pathlib.Path(os.environ["MANIFEST"])

def split_frontmatter(text):
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 4)
    if end == -1:
        return {}, text
    raw = text[4:end]
    body = text[end:].split("\n", 2)
    body = body[2] if len(body) > 2 else ""
    try:
        data = yaml.safe_load(raw) or {}
    except yaml.YAMLError:
        return {}, text
    return (data if isinstance(data, dict) else {}), body

def emit(path, fm, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    fm_text = yaml.safe_dump(fm, default_flow_style=False, sort_keys=False, allow_unicode=True, width=100)
    path.write_text(f"---\n{fm_text}---\n\n{body.lstrip()}")

written = []

agents_src = src / "agents"
if agents_src.is_dir():
    for f in sorted(agents_src.glob("*.md")):
        try:
            data, body = split_frontmatter(f.read_text())
        except OSError:
            print(f"skip (unreadable): {f}", file=sys.stderr)
            continue
        fm = {"description": str(data.get("description", f.stem)).strip(), "mode": "subagent"}
        rel = pathlib.Path("agents") / f.name
        emit(dst / rel, fm, body)
        written.append(str(rel))

commands_src = src / "commands"
if commands_src.is_dir():
    for f in sorted(commands_src.rglob("*.md")):
        try:
            data, body = split_frontmatter(f.read_text())
        except OSError:
            print(f"skip (unreadable): {f}", file=sys.stderr)
            continue
        fm = {"description": str(data.get("description", f.stem)).strip()}
        rel = pathlib.Path("commands") / f.relative_to(commands_src)
        emit(dst / rel, fm, body)
        written.append(str(rel))

manifest_path.write_text("\n".join(written) + "\n")
print(f"synced {len(written)} files into {dst} ({len([w for w in written if w.startswith('agents')])} agents, {len([w for w in written if w.startswith('commands')])} commands)")
PYEOF
