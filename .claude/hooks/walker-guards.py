#!/usr/bin/env python3
"""PreToolUse(Bash): the guards that walk a command with forge-guard's walker, in one process.

forge-guard, checkout-guard, release-guard, scratch-rm-guard and gh-login-guard each keep their
logic and their own file; this reads the payload once and asks each one's decide(data). One Python
start per Bash call instead of five, and forge-guard is loaded once and shared. Every guard that
refuses is named in the one deny, as when they ran as five hooks. A guard that raises is skipped,
the others still run: each one fails open on its own, as before.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARDS = ("forge-guard", "checkout-guard", "release-guard", "scratch-rm-guard", "gh-login-guard")


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def reasons(data):
    out, forge = [], None
    for name in GUARDS:
        try:
            mod = load(name)
            if name == "forge-guard":
                forge = mod
            elif forge:
                mod.FORGE = forge
            r = mod.decide(data)
        except Exception as e:  # stderr on exit 0 reaches the transcript, never the model
            print("walker-guards: %s skipped, it raised %r" % (name, e), file=sys.stderr)
            continue
        if r:
            out.append(r)
    return out


def main():
    rs = reasons(json.load(sys.stdin))
    if rs:
        print(json.dumps({"hookSpecificOutput": {
            # gate: hook-walker-guards
            "hookEventName": "PreToolUse", "permissionDecision": "deny",
            "permissionDecisionReason": "\n\n".join(rs)}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
