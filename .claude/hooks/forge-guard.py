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
`git push` to a github.com remote (an ssh Host alias is resolved with `ssh -G`).

Anywhere else, `gh pr merge` is denied too, naming `agent-land`: a GitHub PR lands through
agent-land, the one writer of a queue item's pr:, so the work ledger can credit it. 2026-11-09: of
the 62 merged PRs since 11-07 that no item named (fleet-bench ledger_coverage), 41 were merged by a
bare `gh pr merge` in a session that had an item (ar-1153). The checkout is
the one each segment runs in: the payload cwd, moved by `cd`/`pushd` earlier in the command (a
subshell's cd stays in it), then `git -C <dir>`; for `gh -R <owner>/<repo>`, GH_REPO or a PR URL,
the clone project-map.json `paths` lists under that repo name. `bash -c` and `eval` payloads and
backticks are checked as code. Not covered: `gh api` writes, `--git-dir`, and an unresolvable cd
target ($(...)), which allow. Fail-open: any error allows the command.
"""
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARKERS = (".forgejo/workflows/mirror-to-github.yaml", ".forgejo/workflows/mirror-to-github.yml")
SEPARATORS = set(";&|()")
NL = "\x1e"  # newline sentinel: a separator that also ends a comment
PREFIXES = {"env", "command", "builtin", "exec", "time", "nohup", "sudo", "then", "do", "else", "elif", "{", "!"}
SHELLS = {"bash", "sh", "zsh", "dash"}
GIT_OPT_ARG = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
PUSH_OPT_ARG = {"-o", "--push-option", "--receive-pack", "--exec"}

MSG = (
    "forge-guard: {top} is a Forgejo-canonical checkout (it commits {marker}), so GitHub is a "
    "passive mirror: {what} lands on the mirror, where Flux never sees it and the next mirror push "
    "erases it. Push to the Forgejo remote ({forgejo}) and open and merge the PR through the "
    "forgejo-ops skill's PR API; agent-land cannot run there (one-shot step 6). Read that repo's "
    "CLAUDE.md \"Canonical Remote\" first."
)

LAND_MSG = (
    "forge-guard: `gh pr merge` records the PR on no queue item, so the work ledger never credits it "
    "(fleet-bench ledger_coverage). From the PR's own checkout, run `agent-land {pr}{repo}`: it adds the "
    "\"Item: <slug>\" line, waits for the checks, merges, and records the PR on this session's item "
    "(--item <slug> names another; --partial on every PR of a task but its last). A PR already merged: "
    "the same command records it. No item yet: `agent-queue add --running` first."
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
    """The command in order: each simple command as a word list (redirections dropped), and each
    separator as its token, so the caller can scope a subshell's cd. Backticks split like `;`."""
    text = cmd.replace("\\\n", " ").replace("\n", " %s " % NL).replace("`", " ; ")
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""  # shlex ends a word at a mid-word `#` (fix#3); bash does not
    seg, comment, skip = [], False, False
    for tok in lex:
        if tok == NL or (tok and set(tok) <= SEPARATORS):
            comment = skip = False
            if seg:
                yield seg
            seg = []
            yield tok
        elif comment:
            continue
        elif skip:
            skip = False
        elif tok.startswith("#"):
            comment = True
        elif tok and set(tok) <= set("<>&|") and ("<" in tok or ">" in tok):
            if seg and seg[-1].isdigit():
                seg.pop()  # the 2 of 2>&1
            skip = True  # the redirection target
        else:
            seg.append(tok)
    if seg:
        yield seg


def unwrap(argv):
    """Drop leading VAR=value assignments, keywords and wrappers (env -i, sudo, then, ...)."""
    env, wrapped = {}, False
    while argv:
        a = argv[0]
        if "=" in a and not a.startswith("=") and a.split("=", 1)[0].isidentifier():
            k, v = a.split("=", 1)
            env[k] = v
        elif a in PREFIXES:
            wrapped = True
        elif wrapped and a.startswith("-"):
            pass
        else:
            break
        argv = argv[1:]
    return argv, env


def resolve(base, path):
    """base/path, or None when either is unknown (an unset variable, a $(...))."""
    path = os.path.expandvars(os.path.expanduser(path))
    if "$" in path or (base is None and not os.path.isabs(path)):
        return None
    return os.path.normpath(os.path.join(base or "/", path))


def canonical(d):
    """(toplevel, marker) when directory d is inside a Forgejo-canonical checkout, else None."""
    if not d or not os.path.isdir(d):
        return None
    top = git(d, "rev-parse", "--show-toplevel")
    for m in MARKERS:
        if top and os.path.isfile(os.path.join(top, m)):
            return top, m
    return None


def host(url):
    m = re.match(r"^[a-z+]+://(?:[^@/]*@)?([^/:]+)", url) or re.match(r"^(?:[^@/]*@)?([^/:]+):", url)
    if not m:
        return ""
    h = m.group(1).lower()
    if "." not in h:  # an ssh Host alias: ask ssh what it names
        r = subprocess.run(["ssh", "-G", h], capture_output=True, text=True, timeout=2)
        h = next((l.split()[1] for l in r.stdout.splitlines() if l.startswith("hostname ")), h)
    return h


def is_github(url):
    h = host(url)
    return h == "github.com" or h.endswith(".github.com")


def forgejo_remote(top):
    names = git(top, "remote").split()
    good = [n for n in names if not is_github(git(top, "remote", "get-url", "--push", n))]
    return "`git push %s <branch>`" % good[0] if good else "the Forgejo remote"


def clone_for(slug):
    """The local clone project-map.json lists under the repo name in <owner>/<repo>."""
    name = slug.rstrip("/").split("/")[-1].removesuffix(".git")
    path = os.environ.get("PROJECT_MAP_FILE") or os.path.expanduser("~/.config/shared-hooks/project-map.json")
    try:
        with open(path) as f:
            paths = json.load(f).get("paths") or {}
    except (OSError, ValueError, AttributeError):
        return None
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


def git_verb(cwd, argv):
    """(directory, index of the subcommand) of a git argv, past -C and git's own options."""
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
    return d, i


def check_git(cwd, argv):
    d, i = git_verb(cwd, argv)
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


def gh_words(argv):
    """gh's command words, without its flags: `gh -R o/r pr merge 1` is a merge too."""
    words, rest = [], iter(argv[1:])
    for a in rest:
        if a in ("-R", "--repo"):
            next(rest, None)
        elif not a.startswith("-"):
            words.append(a)
    return words


def check_gh(cwd, argv, env):
    words = gh_words(argv)
    if words[:1] != ["pr"] or words[1:2] not in (["create"], ["merge"]):
        return None
    slug = env.get("GH_REPO") or os.environ.get("GH_REPO")
    pr = next((w for w in words[2:] if w.isdigit()), "<N>")
    for j, a in enumerate(argv):
        url = re.search(r"github\.com/([^/\s]+/[^/\s]+)/pull/([0-9]+)", a)
        if url:
            slug, pr = url.group(1), url.group(2)
        elif a in ("-R", "--repo") and j + 1 < len(argv):
            slug = argv[j + 1]
        elif a.startswith("--repo="):
            slug = a.split("=", 1)[1]
    hit = canonical(clone_for(slug) if slug else cwd)
    if hit:
        top, marker = hit
        return MSG.format(top=top, marker=marker, what="`gh pr %s`" % words[1], forgejo=forgejo_remote(top))
    if words[1] == "merge":
        return LAND_MSG.format(pr=pr, repo=" --repo %s" % slug if slug else "")
    return None


def check_land(cwd):
    hit = canonical(cwd)
    if not hit:
        return None
    top, marker = hit
    return MSG.format(top=top, marker=marker, what="`agent-land` (it merges with gh)", forgejo=forgejo_remote(top))


def check(head, argv, env, cwd):
    if head == "git":
        return check_git(cwd, argv)
    if head == "gh":
        return check_gh(cwd, argv, env)
    if head == "agent-land":
        return check_land(cwd)
    return None


def reason(cmd, cwd, check=check):
    """The first refusal check(head, argv, env, cwd) gives a simple command of cmd, walked in
    order with its directory tracked. checkout-guard.py walks with its own check."""
    subshells, dirs = [], []
    for seg in segments(_strip_heredocs()(cmd)):
        if isinstance(seg, str):
            for ch in seg:
                if ch == "(":
                    subshells.append(cwd)
                elif ch == ")" and subshells:
                    cwd = subshells.pop()
            continue
        argv, env = unwrap(seg)
        if not argv:
            continue
        head = os.path.basename(argv[0])
        r = None
        if head in ("cd", "pushd"):
            args = [a for a in argv[1:] if a == "-" or not a.startswith("-")]
            target = args[0] if args else "~"
            if target != "-":
                if head == "pushd":
                    dirs.append(cwd)
                cwd = resolve(cwd, target)
        elif head == "popd" and dirs:
            cwd = dirs.pop()
        elif head in SHELLS:
            c = next((j for j, a in enumerate(argv[1:], 1) if re.fullmatch(r"-[a-z]*c[a-z]*", a)), None)
            if c is not None and c + 1 < len(argv):
                r = reason(argv[c + 1], cwd, check)
        elif head == "eval":
            r = reason(" ".join(argv[1:]), cwd, check)
        else:
            r = check(head, argv, env, cwd)
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
