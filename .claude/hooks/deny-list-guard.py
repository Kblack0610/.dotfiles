#!/usr/bin/env python3
"""PreToolUse(Bash) guard for Codex: refuse what Claude's permissions.deny refuses.

Claude enforces its `Bash(...)` denies itself. Codex gets them two ways: sync-codex-home.sh renders
the whole-word ones as execpolicy `forbidden` rules (they bind even where hooks are not trusted),
and this hook applies every entry with Claude's glob meaning, so the ones execpolicy cannot express
(`rm -rf ~`, `rm -rf /*`, `curl * | sh`, `git clean -fd*` as `-fdq`) bind too. One list: the deny
entries in $CLAUDE_HOME/settings.json; nothing is listed here.

Each simple command of the line is matched as written and past each wrapper word (VAR=value,
`sudo`, `env`), walked with forge-guard's splitter, `bash -c` and `eval` included. An entry with
a pipe or a redirect is matched against the whole line. Fail-open: any error allows the command.
"""
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OPERATORS = set("|<>")

MSG = (
    "deny-list-guard: Claude's settings.json denies Bash({entry}), and a Codex run is held to the "
    "same list. Do it another way, or stop and ask the human."
)


def _forge():
    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def squeeze(s):
    """One space between words, none around a pipe or redirect, so `a | b` and `a|b` read alike."""
    return re.sub(r"\s*([|<>])\s*", r"\1", " ".join(s.split()))


def entries(settings):
    """(entry, compiled pattern, whole-line?) for each Bash(...) deny, `*` meaning any text as in
    Claude. `x:*` is the old prefix form. A pipe or redirect entry matches anywhere in the line, up
    to a word end."""
    with open(settings) as f:
        deny = (json.load(f).get("permissions") or {}).get("deny") or []
    out = []
    for d in deny:
        if not (isinstance(d, str) and d.startswith("Bash(") and d.endswith(")")):
            continue
        e = d[5:-1].strip()
        glob = squeeze(e[:-2] + "*" if e.endswith(":*") else e)
        rx = ".*".join(re.escape(p) for p in glob.split("*"))
        whole = bool(OPERATORS & set(e))
        if whole and not glob.endswith("*"):
            rx += r"(?![\w.-])"
        out.append((e, re.compile(rx), whole))
    return out


def walk(forge, cmd):
    """Each simple command of cmd, as written and unwrapped, recursing into `sh -c` and eval."""
    for seg in forge.segments(forge._strip_heredocs()(cmd)):
        if isinstance(seg, str):
            continue
        argv, _ = forge.unwrap(seg)
        for i in range(len(seg) - len(argv) + 1):  # as written, then past each dropped word
            yield " ".join(seg[i:])
        if not argv:
            continue
        head = os.path.basename(argv[0])
        if head in forge.SHELLS:
            c = next((j for j, a in enumerate(argv[1:], 1) if re.fullmatch(r"-[a-z]*c[a-z]*", a)), None)
            if c is not None and c + 1 < len(argv):
                yield from walk(forge, argv[c + 1])
        elif head == "eval":
            yield from walk(forge, " ".join(argv[1:]))


def reason(cmd, settings):
    rules = entries(settings)
    if not rules:
        return None
    line = squeeze(cmd)
    for e, rx, whole in rules:
        if whole and rx.search(line):
            return MSG.format(entry=e)
    words = list(walk(_forge(), cmd))
    for e, rx, whole in rules:
        if not whole and any(rx.fullmatch(w) for w in words):
            return MSG.format(entry=e)
    return None


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    settings = os.path.join(os.environ.get("CLAUDE_HOME", os.path.expanduser("~/.claude")), "settings.json")
    r = cmd.strip() and reason(cmd, settings)
    if r:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
