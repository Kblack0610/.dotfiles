#!/usr/bin/env python3
"""PreToolUse(Bash) guard: keep the checkouts stow deploys on their default branch.

Stow links $HOME at ~/.dotfiles and ~/.dotfiles-private, so whatever they have checked out is what
every session runs. 2026-11-06 13:47: a /code-review subagent (session 5d8358a8) reviewing PR 1240
ran `cd ~/.dotfiles; git checkout -q --detach origin/fix/budget-stop-triage-judge`. For nearly six
minutes every stowed script ran that branch's code, the fast-forward pulls could not advance main,
and all 16 sessions there read STALLED on its 9 files.

Denied in such a checkout: `git checkout` and `git switch` to anything but the default branch, a
new branch or --detach, and `gh pr checkout`. Going back to the default branch and restoring files
are allowed. A linked worktree is a different toplevel, so it is never touched. The directory each
command runs in comes from forge-guard's walker, which also sets what is not covered.
`fleet-sessions` CHECKOUT rows and the main-checkout-branch watch catch what gets past this.
Fail-open: any error allows the command.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NEW_BRANCH = {"-b", "-B", "-c", "-C", "--orphan", "--detach", "-d"}

MSG = (
    "checkout-guard: {top} is the checkout stow deploys, so {what} would make every session run "
    "that code and stop the fast-forward pulls. Read a ref without moving HEAD (`git show "
    "<ref>:<path>`, `git diff main...<ref>`) or use a worktree (`wt new`, or `git worktree add "
    "~/.worktrees/<repo>-<slug> <ref>`)."
)


def _forge():
    import importlib.util

    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FORGE = None  # loaded past main's prefilter: this hook runs on every Bash call


def deployed(d):
    """The toplevel of directory d when it is a checkout stow deploys, else None."""
    if not d or not os.path.isdir(d):
        return None
    top = FORGE.git(d, "rev-parse", "--show-toplevel")
    roots = (os.environ.get("DOTFILES", "~/.dotfiles"), os.environ.get("DOTFILES_PRIVATE", "~/.dotfiles-private"))
    if top and os.path.realpath(top) in {os.path.realpath(os.path.expanduser(r)) for r in roots}:
        return top
    return None


def moves_head(top, verb, args):
    """True when `git <verb> <args>` would leave the default branch. `--` makes a checkout a file
    restore, and so do two words or a word that names no commit."""
    if verb == "checkout" and "--" in args:
        return False
    if NEW_BRANCH & set(args):
        return True
    words = [a for a in args if a == "-" or not a.startswith("-")]
    if not words or (verb == "checkout" and len(words) > 1):
        return False
    target = words[0]
    default = FORGE.git(top, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD").removeprefix("origin/") or "main"
    if target == default:
        return False
    return target == "-" or verb == "switch" or bool(FORGE.git(top, "rev-parse", "-q", "--verify", target + "^{commit}"))


def check(head, argv, env, cwd):
    if head == "gh" and argv[1:3] == ["pr", "checkout"]:
        top = deployed(cwd)
        return MSG.format(top=top, what="`gh pr checkout`") if top else None
    if head != "git":
        return None
    d, i = FORGE.git_verb(cwd, argv)
    if i >= len(argv) or argv[i] not in ("checkout", "switch"):
        return None
    top = deployed(d)
    if top and moves_head(top, argv[i], argv[i + 1 :]):
        return MSG.format(top=top, what="`git %s`" % " ".join(argv[i : i + 4]))
    return None


def main():
    global FORGE
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not any(w in cmd for w in ("checkout", "switch")):
        return
    FORGE = _forge()
    r = FORGE.reason(cmd, data.get("cwd") or os.getcwd(), check)
    if r:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
