#!/usr/bin/env python3
"""PreToolUse(Bash) guard: deny a bare `pip install`, naming uv. walker-guards.py runs it.

The command is read as code the way hand_methods.py reads it for a skill's replaces rows: quoted
text is blanked unless it runs (`bash -c`, eval, ssh, watch, xargs, su), heredoc bodies go, and
each $(...) body counts. So `rg 'pip install'` or a commit message passes, while
`ssh h "pip install x"` is denied. Denied: `pip` or `pip3`, any path, then flags, then `install`
(`python3 -m pip -q install`); `uv pip install`, the form the deny advises, passes. Fail-open:
any error allows.
"""
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PIP = re.compile(r"(?<![\w.-])pip3?(?:\s+-\S+)*\s+install(?![\w.-])")
UV = re.compile(r"(?:^|[;&|(){}\s])uv\s+$")
MSG = "block-pip: Use `uv add <pkg>` or `uv pip install <pkg>` instead of bare pip."

HM = None  # hand_methods.py, loaded past decide's prefilter


def _hand_methods():
    spec = importlib.util.spec_from_file_location("hand_methods", os.path.join(HERE, "hand_methods.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def bare(text):
    return any(not UV.search(text[: m.start()]) for m in PIP.finditer(text))


# gate: hook-block-pip
def decide(data):
    """The deny reason for one PreToolUse payload, or None. walker-guards.py calls this."""
    global HM
    if data.get("tool_name", "Bash") != "Bash":
        return None
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if "pip" not in cmd or "install" not in cmd:
        return None
    HM = HM or _hand_methods()
    return MSG if any(bare(t) for t in HM.code_texts(cmd)) else None


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
