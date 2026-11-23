#!/usr/bin/env python3
"""PreToolUse(Bash) guard: deny a bare `pip install`, naming uv. walker-guards.py runs it.

Each simple command forge-guard's walker reaches (cd, subshells, `bash -c`, eval) is read as words,
so pip in quoted or grepped text (`rg 'pip install'`, a commit message) is not a command and passes;
as block-pip.sh, a regex over the raw text, it was denied. Denied: `pip` or `pip3` followed by
`install` anywhere in a command's words (`pip install`, `python3 -m pip install`, `xargs pip
install`). `uv pip install`, the form the deny advises, passes. Fail-open: any error allows.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PIP = ("pip", "pip3")
MSG = "block-pip: Use `uv add <pkg>` or `uv pip install <pkg>` instead of bare pip."

FORGE = None  # loaded past decide's prefilter, or set by walker-guards.py: it runs on every Bash call


def _forge():
    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def check(head, argv, env, cwd):
    for i, w in enumerate(argv[:-1]):
        if os.path.basename(w) in PIP and argv[i + 1] == "install" and not (i and argv[i - 1] == "uv"):
            return MSG
    return None


def decide(data):
    """The deny reason for one PreToolUse payload, or None. walker-guards.py calls this."""
    global FORGE
    if data.get("tool_name", "Bash") != "Bash":
        return None
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if "pip" not in cmd or "install" not in cmd:
        return None
    FORGE = FORGE or _forge()
    return FORGE.reason(cmd, data.get("cwd") or os.getcwd(), check)


def main():
    r = decide(json.load(sys.stdin))
    if r:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
