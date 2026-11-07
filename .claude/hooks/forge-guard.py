#!/usr/bin/env python3
"""PreToolUse(Bash) guard: in a checkout whose canonical forge is Forgejo, deny the GitHub writes.

A repo says Forgejo is canonical by committing `.forgejo/workflows/mirror-to-github.yaml` (or
.yml): Forgejo pushes to GitHub, so the GitHub copy is a passive mirror (home-config docs/gitops.md
"Canonical Remote"). A remote alone does not decide it: personal-sites has a Forgejo remote and
runs its CI on GitHub.

2026-11-06: home-config GitHub PR 62 was pushed to `origin` (the mirror), opened with `gh pr create`
and merged with `gh pr merge` 22 seconds later, from a dotfiles session that had `cd`'d into a
home-config worktree, so the home-config lessons never loaded. The mirror's reject-pull-requests
workflow closes a PR only after it opens, too late to stop that merge.

Denied in such a checkout: `gh pr create`, `gh pr merge`, `agent-land` (it merges with gh), and
`git push` to a github.com remote. The checkout is the one each segment runs in: the payload cwd,
moved by `cd`/`pushd` earlier in the command, then `git -C <dir>`; for `gh -R <owner>/<repo>`, the
clone project-map.json `paths` lists under that repo name. Fail-open: any error allows the command.
"""
import importlib.util
import json
import os
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARKERS = (".forgejo/workflows/mirror-to-github.yaml", ".forgejo/workflows/mirror-to-github.yml")
SEPARATORS = set(";&|()")
WRAPPERS = {"env", "command", "builtin", "exec", "time", "nohup"}
GIT_OPT_ARG = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
PUSH_OPT_ARG = {"-o", "--push-option", "--receive-pack", "--exec"}

MSG = (
    "forge-guard: {top} is a Forgejo-canonical checkout (it commits {marker}), so GitHub is a "
    "passive mirror: {what} lands on the mirror, where Flux never sees it and the next mirror push "
    "erases it. Push to the Forgejo remote ({forgejo}) and open and merge the PR through the "
    "forgejo-ops skill's PR API; agent-land cannot run there (one-shot step 6). Read that repo's "
    "CLAUDE.md \"Canonical Remote\" first."
)


def _strip_heredocs():
    spec = importlib.util.spec_from_file_location("block_poll", os.path.join(HERE, "block-poll.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.strip_heredocs


def git(top, *args):
    r = subprocess.run(["git", "-C", top, *args], capture_output=True, text=True, timeout=3)
    return r.stdout.strip() if r.returncode == 0 else ""


def segments(cmd):
    """The command's simple commands, each a word list, in order."""
    # "\n ; " and not " ; ": shlex eats a comment through its newline, so the separator goes after it.
    lex = shlex.shlex(cmd.replace("\\\n", " ").replace("\n", "\n ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    seg = []
    for tok in lex:
        if tok and set(tok) <= SEPARATORS:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def unwrap(argv):
    """Drop leading VAR=value assignments and wrappers (env, command, time, ...)."""
    env = {}
    while argv:
        a = argv[0]
        if "=" in a and not a.startswith("=") and a.split("=", 1)[0].isidentifier():
            k, v = a.split("=", 1)
            env[k] = v
        elif a in WRAPPERS:
            pass
        else:
            break
        argv = argv[1:]
    return argv, env


def resolve(base, path):
    return os.path.normpath(os.path.join(base, os.path.expanduser(path)))


def canonical(d):
    """(toplevel, marker) when directory d is inside a Forgejo-canonical checkout, else None."""
    if not d or not os.path.isdir(d):
        return None
    top = git(d, "rev-parse", "--show-toplevel")
    for m in MARKERS:
        if top and os.path.isfile(os.path.join(top, m)):
            return top, m
    return None


def is_github(url):
    return "github.com" in url


def forgejo_remote(top):
    names = git(top, "remote").split()
    good = [n for n in names if not is_github(git(top, "remote", "get-url", "--push", n))]
    return "`git push %s <branch>`" % good[0] if good else "the Forgejo remote"


def clone_for(slug):
    """The local clone project-map.json lists under the repo name in <owner>/<repo>."""
    name = slug.rstrip("/").split("/")[-1].removesuffix(".git")
    path = os.environ.get("PROJECT_MAP_FILE") or os.path.expanduser("~/.config/shared-hooks/project-map.json")
    with open(path) as f:
        paths = json.load(f).get("paths") or {}
    for p, n in paths.items():
        if n == name or os.path.basename(p.rstrip("/")) == name:
            return os.path.expanduser(p)
    return None


def push_target(top, args):
    """The remote (name or URL) a `git push <args>` writes to."""
    pos, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1 :])
            break
        if a.startswith("--repo="):
            return a.split("=", 1)[1]
        if a == "--repo" and i + 1 < len(args):
            return args[i + 1]
        if a in PUSH_OPT_ARG:
            i += 2
            continue
        if not a.startswith("-"):
            pos.append(a)
        i += 1
    if pos:
        return pos[0]
    branch = git(top, "symbolic-ref", "--short", "-q", "HEAD")
    keys = ["branch.%s.pushRemote" % branch, "remote.pushDefault", "branch.%s.remote" % branch] if branch else ["remote.pushDefault"]
    for key in keys:
        v = git(top, "config", "--get", key)
        if v:
            return v
    return "origin"


def check_git(cwd, argv):
    d, i = cwd, 1
    while i < len(argv):
        a = argv[i]
        if a == "-C" and i + 1 < len(argv):
            d = resolve(d, argv[i + 1])
            i += 2
        elif a in GIT_OPT_ARG:
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            break
    if i >= len(argv) or argv[i] != "push":
        return None
    hit = canonical(d)
    if not hit:
        return None
    top, marker = hit
    target = push_target(top, argv[i + 1 :])
    url = git(top, "remote", "get-url", "--push", target) or target
    if not is_github(url):
        return None
    return MSG.format(top=top, marker=marker, what="`git push %s` (%s)" % (target, url), forgejo=forgejo_remote(top))


def check_gh(cwd, argv, env):
    if len(argv) < 3 or argv[1] != "pr" or argv[2] not in ("create", "merge"):
        return None
    slug = env.get("GH_REPO") or os.environ.get("GH_REPO")
    for j, a in enumerate(argv):
        if a in ("-R", "--repo") and j + 1 < len(argv):
            slug = argv[j + 1]
        elif a.startswith("--repo="):
            slug = a.split("=", 1)[1]
    hit = canonical(clone_for(slug) if slug else cwd)
    if not hit:
        return None
    top, marker = hit
    return MSG.format(top=top, marker=marker, what="`gh pr %s`" % argv[2], forgejo=forgejo_remote(top))


def check_land(cwd):
    hit = canonical(cwd)
    if not hit:
        return None
    top, marker = hit
    return MSG.format(top=top, marker=marker, what="`agent-land` (it merges with gh)", forgejo=forgejo_remote(top))


def reason(cmd, cwd):
    stack = []
    for seg in segments(_strip_heredocs()(cmd)):
        argv, env = unwrap(seg)
        if not argv:
            continue
        head = os.path.basename(argv[0])
        if head in ("cd", "pushd"):
            target = argv[1] if len(argv) > 1 and argv[1] != "--" else (argv[2] if len(argv) > 2 else "~")
            if target != "-":
                if head == "pushd":
                    stack.append(cwd)
                cwd = resolve(cwd, target)
        elif head == "popd" and stack:
            cwd = stack.pop()
        elif head == "git":
            r = check_git(cwd, argv)
            if r:
                return r
        elif head == "gh":
            r = check_gh(cwd, argv, env)
            if r:
                return r
        elif head == "agent-land":
            r = check_land(cwd)
            if r:
                return r
    return None


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not any(w in cmd for w in ("push", "gh", "agent-land")):
        return
    r = reason(cmd, data.get("cwd") or os.getcwd())
    if r:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
