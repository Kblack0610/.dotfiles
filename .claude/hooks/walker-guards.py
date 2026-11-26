#!/usr/bin/env python3
"""PreToolUse(Bash): the Bash guards, in one process.

forge-guard, checkout-guard, release-guard, scratch-rm-guard, gh-login-guard, shared-state-guard,
block-pip, block-poll, python-write-guard and skip-guard each keep their logic and their own file; this reads
the payload once and asks each one's decide(data). One Python start per Bash call instead of nine,
and forge-guard's walker is loaded once and shared. Every guard that refuses is named in the one deny, as when they
ran as separate hooks. A guard that raises is skipped, the others still run: each one fails open on
its own, as before. block-poll's Read deny is its own hook (settings.json), since this runs on Bash.
"""
import sys

import hooklib

GUARDS = ("forge-guard", "checkout-guard", "release-guard", "scratch-rm-guard", "gh-login-guard",
          "shared-state-guard", "block-pip", "block-poll", "python-write-guard", "skip-guard")


def reasons(data):
    out, forge = [], None
    for name in GUARDS:
        try:
            mod = hooklib.load(name)
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


# gate: hook-walker-guards
def decide(data):
    """Every refusing guard's reason in one deny, or None."""
    return "\n\n".join(reasons(data)) or None


if __name__ == "__main__":
    hooklib.run(decide)
