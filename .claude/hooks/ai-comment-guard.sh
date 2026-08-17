#!/usr/bin/env bash
# ai-comment-guard.sh - PostToolUse guard for Edit/Write/MultiEdit.
#
# Flags AI-tell comments in the text an agent just wrote. A rule in CLAUDE.md is
# advisory: the model reads it at session start and may or may not act on it, and
# a session already running when the rule landed never sees it at all. This is the
# enforcement half - it inspects what was actually written.
#
# WARNS, does not block. Exit 2 feeds stderr back to the model so it can fix the
# line it just wrote. Blocking was rejected deliberately: a repo-wide measurement
# of these patterns against well-commented prose ran near 100% false positives on
# the loose forms, so the patterns below are the tightened ones (line-initial
# comment marker + diary phrasing) and even those are advisory.
#
# Disable: export CLAUDE_SKIP_COMMENT_GUARD=1

set -uo pipefail
[ "${CLAUDE_SKIP_COMMENT_GUARD:-0}" = "1" ] && exit 0

payload=$(cat)

added=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input", {}) or {}
out = []
if "content" in ti:
    out.append(ti["content"])
if "new_string" in ti:
    out.append(ti["new_string"])
for e in ti.get("edits", []) or []:
    if isinstance(e, dict) and "new_string" in e:
        out.append(e["new_string"])
print("\n".join(x for x in out if isinstance(x, str)))
' 2>/dev/null)

[ -z "$added" ] && exit 0

path=$(printf '%s' "$payload" | python3 -c 'import json,sys;print((json.load(sys.stdin).get("tool_input") or {}).get("file_path",""))' 2>/dev/null)
case "$path" in
  */node_modules/*|*/dist/*|*.min.*|*.generated.*|*/CHANGELOG.md) exit 0 ;;
esac

findings=$(printf '%s' "$added" | python3 -c '
import re, sys

C = r"^\s*(//|#|\*|--|\x27)\s*"   # line-initial comment marker

RULES = [
    ("diary comment - git owns history, not the code",
     re.compile(C + r".*\b(used to (be|do|live|call|return)|previously (this|we|it)|"
                    r"leaving (them|it|this) out|this (used to|was) (be|broken|wrong)|"
                    r"before this (change|fix|pr)|no longer (needed|used)|"
                    r"as requested|per (the )?(review|feedback)|"
                    r"(now|newly) (added|changed|updated|fixed) (to|so|because))\b", re.I)),
    ("changelog marker - belongs in the PR, not the source",
     re.compile(C + r"(NEW|UPDATED?|CHANGED|FIXED|ADDED|REMOVED)\b\s*[:.\-]")),
    ("reassurance - let the code make the claim",
     re.compile(C + r".*\b(production[- ]ready|fully robust|elegantly handles|"
                    r"handles all edge cases|best practice|blazing[- ]fast|"
                    r"cleanly separates)\b", re.I)),
    ("teaching comment - explains the language, not the code",
     re.compile(C + r".*\bthis (is|will be) (an?|the) (async function|promise|"
                    r"helper function|utility function)\b", re.I)),
    ("non-ASCII in a comment - plain-ASCII rule",
     re.compile(C + r".*[^\x00-\x7F]")),
    ("section banner",
     re.compile(r"^\s*(//|#|/\*)\s*[=*_\-]{4,}")),
]

COMMENT_LINE = re.compile(r"^\s*(//|#|\*|/\*|--|\x27)")
SHEBANG = re.compile(r"^#!")

lines = sys.stdin.read().split("\n")

hits = []
for i, line in enumerate(lines, 1):
    if len(line) > 400:
        continue
    for label, rx in RULES:
        if rx.search(line):
            hits.append((label, line.strip()[:110]))
            break

# Block length. The volume defect: every line can say WHY and the block still be
# unreadable. A header gets a little more room than an inline block.
run = 0
start = 0
for i, line in enumerate(lines + [""], 1):
    if COMMENT_LINE.match(line) and not SHEBANG.match(line.strip()):
        if run == 0:
            start = i
        run += 1
        continue
    if run:
        ceiling = 15 if start <= 3 else 10
        if run > ceiling:
            kind = "file header" if start <= 3 else "inline block"
            hits.append((f"{run}-line {kind} (ceiling {ceiling}) - move the depth to docs/ and leave a link",
                         lines[start - 1].strip()[:110]))
    run = 0
for label, line in hits[:6]:
    print(f"  [{label}]\n    {line}")
print(f"  ...and {len(hits)-6} more" if len(hits) > 6 else "", end="")
' 2>/dev/null)

if [ -n "${findings//[[:space:]]/}" ]; then
  {
    echo "ai-comment-guard: the text just written to ${path:-this file} contains comment patterns the project rule prohibits."
    echo "$findings"
    echo
    echo "Fix the comment you just wrote, or say why it should stand. Keep the WHY, drop the history."
    echo "Reference: the 'Code comments and hygiene' rule; the code-hygiene skill has the full keep/kill lists."
  } >&2
  exit 2
fi
exit 0
