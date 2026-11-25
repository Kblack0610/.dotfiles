#!/usr/bin/env python3
"""PreToolUse(Bash) guard: a session does not skip a gate on its own word.

Plan everything-should-wondrous-snail P2 (ar-5448): every check binds only if no path around it is
open to the agent. Three paths were open, each refused only by a prose rule (`ci.md` "--no-verify
is never used", the global "if on the default branch, branch first"):

- `--no-verify` on a git command (commit, push, merge, ...) and `git commit -n`, also in a short
  flag cluster (`-nm msg`): they skip the committed pre-commit leak scan and the pre-push checks.
- core.hooksPath moved: for one command (`git -c core.hooksPath=...`, `--config-env`, a
  GIT_CONFIG_PARAMETERS or GIT_CONFIG_KEY_<n> prefix) or written by `git config`, which points git
  at a directory with no hooks. Reading it passes. The global config that sets it is dropped the
  same way, so a hooked verb under a GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, GIT_CONFIG_NOSYSTEM,
  HOME or XDG_CONFIG_HOME prefix is denied, and so is `git config --edit`.
- a `git push` to origin (or the remote origin/HEAD names, forgejo in home-config), by name or
  URL, whose destination is the repo's default branch (merge_proof_branch, the one reader, as
  checkout-guard reads it): by refspec (`main`, `HEAD:main`, `+x:refs/heads/main`, `:main`),
  `--all`/`--branches`/`--mirror`/`:`, or a bare push that writes it (from that branch, from a
  branch tracking it under push.default=upstream, any branch under matching, or a
  remote.<name>.push refspec). Such a push lands with no PR, so no required check runs first. A
  dry run and a push to another remote pass.

Not covered: git calls inside a script (store-sync and fleet-lease commit to their own stores with
`-c core.hooksPath=/dev/null`), an `export` of GIT_CONFIG_* or HOME earlier in the command, `env -i`,
a hand edit of .git/config or ~/.gitconfig, and a repo with
no default branch on origin (~/.notes and ~/.agent push to `backup`), which allow. The human runs a
bypass by hand when one is meant. It walks the command with forge-guard's walker. Fail-open: any
error allows the command.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOOKED = {"commit", "push", "merge", "pull", "am", "rebase", "cherry-pick", "revert"}
# git commit's flags that take a value: a short one ends its cluster, so `-mn` is a message "n".
COMMIT_SHORT_VALUE = set("mFCct")
COMMIT_SHORT_OPTIONAL = set("uS")  # take only an attached value: `-uno` is not -n
COMMIT_LONG_VALUE = {"--message", "--file", "--reuse-message", "--reedit-message", "--fixup", "--squash", "--author",
                     "--date", "--template", "--trailer", "--cleanup", "--pathspec-from-file"}
# Each hooked verb's flags that take the next word as a value, so `rebase -x '--no-verify'` is a
# command, not the flag. commit's short ones are COMMIT_SHORT_VALUE; push's are FORGE.PUSH_OPT_ARG.
STRATEGY = {"-s", "--strategy", "-X", "--strategy-option"}
VERB_VALUE = {
    "commit": COMMIT_LONG_VALUE,
    "rebase": STRATEGY | {"-x", "--exec", "--onto"},
    "merge": STRATEGY | {"-m", "-F", "--file"},
    "pull": STRATEGY,
    "cherry-pick": STRATEGY | {"-m", "--mainline"},
    "revert": STRATEGY | {"-m", "--mainline"},
}
# Prefixes that drop the global or system config, where the hook dispatcher's core.hooksPath lives.
CONFIG_ENV = {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "HOME", "XDG_CONFIG_HOME"}
CONFIG_VALUE_OPTS = {"-f", "--file", "--blob", "--type", "--default", "--comment", "--value"}
CONFIG_READ = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "-l", "--list"}
CONFIG_EDIT = {"-e", "--edit", "edit"}
CONFIG_WRITE = {"--unset", "--unset-all", "--add", "--replace-all"}
PUSH_ALL = {"--all", "--branches", "--mirror"}
KEY = "core.hookspath"  # git config keys are case-insensitive

VERIFY_MSG = (
    "skip-guard: {what} skips the repo's committed hooks (the pre-commit leak scan, the pre-push "
    "checks). Fix what the hook refused; a hook that is wrong is fixed in its `.githooks/` file by "
    "PR. Only the human bypasses a hook, by hand."
)
HOOKSPATH_MSG = (
    "skip-guard: {what} moves core.hooksPath, so git runs none of the repo's committed hooks. The "
    "hooks come from the one global dispatcher (`~/.config/git/hooks`, docs/operations/git-hooks.md), "
    "set in the global config, so a prefix that drops that config moves it too; fix what a hook "
    "refused instead. Only the human changes it, by hand."
)
PUSH_MSG = (
    "skip-guard: {what} writes {branch}, the default branch of {top}, with no PR, so no required "
    "check runs before it lands. Push a branch from a worktree cut off origin/{branch} (`wt new`), "
    "open a PR, and land it with `agent-land <N> --item <slug>`."
)

FORGE = None  # set by walker-guards.py, else loaded in decide
CHECKOUT = None


def _load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def env_hookspath(env):
    """True when an inline GIT_CONFIG_* assignment sets core.hooksPath for the command."""
    for k, v in env.items():
        if k == "GIT_CONFIG_PARAMETERS" and KEY in v.lower():
            return True
        if k.startswith("GIT_CONFIG_KEY_") and v.strip().lower() == KEY:
            return True
    return False


def option_hookspath(opts):
    """True when git's own options (before the verb) set core.hooksPath: -c or --config-env."""
    for j, a in enumerate(opts):
        val = opts[j + 1] if a in ("-c", "--config-env") and j + 1 < len(opts) else a.split("=", 1)[1] if a.startswith("--config-env=") else ""
        if val.split("=", 1)[0].strip().lower() == KEY:
            return True
    return False


def config_writes_hookspath(args):
    """True when `git config <args>` sets, unsets or opens an editor on the config; a read passes."""
    words, write, read, it = [], False, False, iter(args)
    for a in it:
        if a in CONFIG_EDIT and not words:
            return True  # an editor can set anything, core.hooksPath included
        if a in CONFIG_VALUE_OPTS:
            next(it, None)
        elif a in CONFIG_WRITE:
            write = True
        elif a in CONFIG_READ:
            read = True
        elif not a.startswith("-"):
            words.append(a)
    if words[:1] in (["set"], ["unset"]):
        write, words = True, words[1:]
    elif words[:1] in (["get"], ["list"]):
        return False
    if not words or words[0].lower() != KEY:
        return False
    return write or (not read and len(words) > 1)


def skips_verify(verb, args):
    """`--no-verify`, or for commit a -n, before any `--`; a flag's value is never read as one."""
    skip = False
    for a in args:
        if skip:
            skip = False
            continue
        if a == "--":
            return False
        if len(a) >= len("--no-veri") and "--no-verify".startswith(a):
            return True  # git takes an unambiguous prefix; --no-ver could be --no-verbose
        if a in VERB_VALUE.get(verb, FORGE.PUSH_OPT_ARG if verb == "push" else ()):
            skip = True
        elif verb == "commit" and a[:1] == "-" and a[:2] != "--":
            for j, c in enumerate(a[1:], 2):
                if c == "n":
                    return True
                if c in COMMIT_SHORT_VALUE:
                    skip = j == len(a)  # a bare -m takes the next word
                    break
                if c in COMMIT_SHORT_OPTIONAL:
                    break
    return False


def push_dests(top, args, remote):
    """The branch names a `git push <args>` to `remote` writes, None for a dry run, ["*"] for every
    branch."""
    pos, all_, repo, i = [], False, False, 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1 :])
            break
        if a in ("-n", "--dry-run") or (a[:1] == "-" and a[:2] != "--" and "n" in a):
            return None
        if a in PUSH_ALL:
            all_ = True
        elif a == "--repo" or a.startswith("--repo="):
            repo = True
            i += a == "--repo"
        elif a in FORGE.PUSH_OPT_ARG:
            i += 1
        elif not a.startswith("-"):
            pos.append(a)
        i += 1
    if all_:
        return ["*"]
    specs = pos if repo else pos[1:]
    branch = FORGE.git(top, "symbolic-ref", "--short", "-q", "HEAD")
    if not specs:
        specs = FORGE.git(top, "config", "--get-all", "remote.%s.push" % remote).split()
    if not specs:
        # push.default simple (git's default) and current write the branch's own name; simple
        # refuses an upstream of another name. upstream (or tracking) writes the upstream, and
        # matching every branch the remote has.
        mode = FORGE.git(top, "config", "--get", "push.default")
        if mode == "matching":
            return ["*"]
        if branch and mode in ("upstream", "tracking"):
            return [FORGE.git(top, "config", "--get", "branch.%s.merge" % branch).removeprefix("refs/heads/")]
        return [branch] if branch else []
    out = []
    for s in specs:
        s = s.lstrip("+")
        if s == ":":
            return ["*"]
        dst = s.split(":", 1)[1] if ":" in s else s
        if dst in ("HEAD", "@"):
            dst = branch
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/") :]
        elif dst.startswith("refs/"):
            continue
        if dst:
            out.append(dst)
    return out


def canonical_remote(top, target):
    """True when a push target (a remote name or URL) is origin, or the remote origin/HEAD names."""
    head = FORGE.git(top, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")
    names = {"origin", head.split("/", 1)[0]} - {""}
    if target in names:
        return True
    urls = {FORGE.git(top, "remote", "get-url", n) for n in names} - {""}
    return target.rstrip("/").removesuffix(".git") in {u.rstrip("/").removesuffix(".git") for u in urls}


def check(head, argv, env, cwd):
    if head != "git":
        return None
    d, i = FORGE.git_verb(cwd, argv)
    if env_hookspath(env) or option_hookspath(argv[1:i]):
        return HOOKSPATH_MSG.format(what="`%s`" % " ".join(argv[: i + 1]))
    if i >= len(argv):
        return None
    verb, args = argv[i], argv[i + 1 :]
    dropped = sorted(CONFIG_ENV & env.keys())
    if verb in HOOKED and dropped:
        return HOOKSPATH_MSG.format(what="`%s=... git %s`" % (dropped[0], verb))
    if verb == "config" and config_writes_hookspath(args):
        return HOOKSPATH_MSG.format(what="`git config %s`" % " ".join(args[:3]))
    if verb in HOOKED and skips_verify(verb, args):
        return VERIFY_MSG.format(what="`git %s`" % " ".join(argv[i : i + 4]))
    if verb != "push" or not d or not os.path.isdir(d):
        return None
    top = FORGE.git(d, "rev-parse", "--show-toplevel")
    remote = FORGE.push_target(top, args) if top else ""
    dests = push_dests(top, args, remote) if remote and canonical_remote(top, remote) else None
    if not dests:
        return None
    global CHECKOUT
    CHECKOUT = CHECKOUT or _load("checkout-guard")
    default = CHECKOUT.default_branch(top)
    if default and (default in dests or "*" in dests):
        return PUSH_MSG.format(what="`git %s`" % " ".join(argv[i : i + 5]), branch=default, top=top)
    return None


def decide(data):
    # gate: hook-skip-guard
    """The deny reason for one PreToolUse payload, or None. walker-guards.py calls this."""
    global FORGE
    if data.get("tool_name", "Bash") != "Bash":
        return None
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if "git" not in cmd:
        return None
    FORGE = FORGE or _load("forge-guard")
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
