"""Shared plumbing for the Python PreToolUse hooks: load a sibling hook, print the deny, run decide().

A hook imports this as `import hooklib`. Python puts the script's real directory (the symlink
followed) on sys.path, so the import finds this file in the checkout the hook itself came from,
before stow has linked it into ~/.claude/hooks. A hook that cannot import it errors with exit 1,
which Claude and Codex read as a non-blocking error, so a missing file fails open (settings.json
also ends each command in `|| true`).
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    """The sibling hook file `<name>.py` (e.g. "forge-guard"), loaded as a module."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def deny(reason):
    """Print the PreToolUse deny that carries reason."""
    # Each hook that calls this names its own register row; this file is the plumbing.
    # gate: none
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))


def run(decide):
    """A hook's entry point: deny when decide(payload) returns a reason. Fail-open, always exit 0."""
    try:
        r = decide(json.load(sys.stdin))
        if r:
            deny(r)
    except Exception:
        pass
    sys.exit(0)
