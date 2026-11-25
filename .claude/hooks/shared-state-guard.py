#!/usr/bin/env python3
"""PreToolUse(Bash) guard: keep a session's hands off state another session or the fleet owns.
walker-guards.py runs it.

The git stash stack is one per repository, shared by every worktree and so by every session in
that repo. A pop, or an apply, drop or `stash branch` with no stash named, takes the top entry,
which may be another session's (2026-11-18: a pop reached another session's
`pr/panel-conformance` entry). Denied: `git stash pop`, `clear`, a bare `apply`, `drop` or
`branch <name>`, and a push (`git stash`, `push`, `save`) with no message to find it by. Allowed:
`list`, `show`, `create`, `store`, a named push, and an apply, drop or branch that names its entry.

An agentctl runner is switched off in its conf: `systemctl --user stop`, `disable` or `mask` of an
`agentctl-*` timer or `agentctl@*` service is undone by the next `agentctl reload` from any
session (2026-11-10: a stopped comms timer was re-armed and work mail reached a non-work-safe
model). Denied: those three verbs on such a unit, naming `agentctl disable|stop|pause`.

The walker is forge-guard's, so `git -C`, `bash -c`, `sudo` and a chain are read as git and bash
read them. Fail-open: any error allows the command.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STASH_SUBS = {"list", "show", "drop", "pop", "apply", "branch", "push", "save", "clear", "create", "store"}
SYSTEMCTL_VERBS = {"stop", "disable", "mask"}
# systemctl's options that take the next word as their value, so it is never read as the verb.
SYSTEMCTL_OPT_ARG = {"-t", "--type", "-s", "--signal", "-p", "--property", "-H", "--host", "-M",
                     "--machine", "-n", "--lines", "-o", "--output", "--root", "--image", "--state",
                     "--job-mode", "--kill-whom", "--what", "--when", "--message"}

STASH_MSG = (
    "shared-state-guard: `git stash {what}` {why}. The stash stack is shared by every worktree "
    "and session in this repo. Set work aside with a WIP commit; if you must stash, "
    "`git stash push -u -m \"<unique-tag>\"`, find your entry's SHA with "
    "`git stash list --format='%H %gs'`, restore with `git stash apply <sha>`, then drop it by "
    "the stash@{{n}} that tag has now."
)
UNIT_MSG = (
    "shared-state-guard: `systemctl {verb} {unit}` is undone by the next `agentctl reload` from "
    "any session. Switch a runner off in its conf with `agentctl disable <name>` (undo: "
    "`agentctl enable <name>`), end one run with `agentctl stop <name>`, or hold the fleet with "
    "`agentctl pause`."
)


def _forge():
    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FORGE = None  # loaded past decide's prefilter, or set by walker-guards.py


def stash_refusal(args):
    """Why `git stash <args>` is denied, or None. With no subcommand word git reads a push."""
    sub, rest = ("push", args)
    if args and args[0] in STASH_SUBS:
        sub, rest = args[0], args[1:]
    words = [a for a in rest if not a.startswith("-")]
    if sub == "pop":
        return "pop", "takes the top entry and may apply another session's work"
    if sub == "clear":
        return "clear", "deletes every session's entries"
    if sub in ("apply", "drop") and not words:
        return sub, "with no entry named takes the top one, which may be another session's"
    if sub == "branch" and len(words) < 2:
        return "branch", "with no entry named takes the top one, which may be another session's"
    if sub == "push" and not any(a in ("-m", "--message") or a.startswith("--message=")
                                 or (a[:1] == "-" and a[:2] != "--" and "m" in a) for a in rest):
        return " ".join(["push"] if not args else args[:3]), "with no -m message leaves an entry no session can tell is yours"
    if sub == "save" and not words:
        return "save", "with no message leaves an entry no session can tell is yours"
    return None


def systemctl_refusal(argv):
    """(verb, unit) when a systemctl argv stops, disables or masks an agentctl unit, else None."""
    i, verb = 1, None
    while i < len(argv):
        a = argv[i]
        if a in SYSTEMCTL_OPT_ARG:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        if verb is None:
            verb = a
            if verb not in SYSTEMCTL_VERBS:
                return None
        elif a.startswith(("agentctl-", "agentctl@")):
            return verb, a
        i += 1
    return None


def check(head, argv, env, cwd):
    if head == "git":
        _, i = FORGE.git_verb(cwd, argv)
        if i < len(argv) and argv[i] == "stash":
            r = stash_refusal(argv[i + 1 :])
            if r:
                return STASH_MSG.format(what=r[0], why=r[1])
        return None
    if head == "systemctl":
        r = systemctl_refusal(argv)
        if r:
            return UNIT_MSG.format(verb=r[0], unit=r[1])
    return None


# gate: hook-shared-state-guard
def decide(data):
    """The deny reason for one PreToolUse payload, or None. walker-guards.py calls this."""
    global FORGE
    if data.get("tool_name", "Bash") != "Bash":
        return None
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if "stash" not in cmd and "agentctl" not in cmd:
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
