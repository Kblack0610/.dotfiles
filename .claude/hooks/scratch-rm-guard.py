#!/usr/bin/env python3
"""PreToolUse(Bash) guard: an rm -r may not remove another live session's cache scratch, or a root dir.

A session keeps large scratch in ~/.cache/<tool>/<session-id>/ (global CLAUDE.md, scratch rule),
so a whole ~/.cache/<tool> dir can hold several sessions' work. 2026-11-10 16:54: session 207ca085
ran an rm -rf of ~/.cache/hub-spend-history and killed session 71d86bf6's backfill and its
original-snapshot copies, kept in its own <session-id> subdir there.

Denied: an `rm` with -r, -R or --recursive whose target is, holds, or sits inside a
<cache>/<tool>/<id> directory, where <id> is the session id of a live session other than the
caller's. <cache> is ~/.cache and $XDG_CACHE_HOME. A session is live while a process of this user
carries its id in CLAUDE_CODE_SESSION_ID (Claude) or CODEX_THREAD_ID (Codex); the caller is the hook
input's session_id. A process still carrying a session's id may still be using its dir, so it
counts as live even after that session's own process exits. The caller's own <id> dir, a dir no
live session owns, and files by name pass. Each command is walked with forge-guard's walker (cd,
subshells, bash -c, eval); brace lists and globs in a target are expanded. Not covered: find
-delete, xargs, a target built by $(...) or a shell variable the hook cannot see, rmtree from a
script. Fail-open: any error allows the command.

Also denied: an `rm -r` whose target is / or a top-level dir, which is what `rm -rf /*` expands to.
Claude's built-in rm check refuses these targets itself; Codex has none, so this is its guard. The
settings.json deny list holds no `Bash(rm -rf /*)`: Claude reads that `*` as a wildcard, so it would
deny every rm -rf of an absolute path, a session's own scratch included (ucp-734).
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ID_VARS = (b"CLAUDE_CODE_SESSION_ID=", b"CODEX_THREAD_ID=")
RECURSIVE = re.compile(r"-[a-zA-Z]*[rR][a-zA-Z]*")

MSG = (
    "scratch-rm-guard: `rm -r {target}` would remove {victim}, the scratch of live session {sid}: "
    "pid {pid} ({comm}) still carries that id. Remove only your own <cache>/<tool>/<your session "
    "id>/ or the files you wrote, by name. If pid {pid} is not that session's work, ask the human."
)
ROOT_MSG = (
    "scratch-rm-guard: `rm -r {target}` would remove {target}, a root dir (what `rm -rf /*` "
    "expands to). Name the path below it you mean; if it really is this dir, ask the human."
)


def _forge():
    import importlib.util

    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FORGE = None  # loaded past main's prefilter: this hook runs on every Bash call
STATE = {}  # caller id, live ids (read once, on first need)


def cache_roots():
    """~/.cache, the rule's path, and $XDG_CACHE_HOME when it is set elsewhere."""
    return {os.path.realpath(r) for r in (os.path.expanduser("~/.cache"), os.environ.get("XDG_CACHE_HOME")) if r}


def as_rm_sees(p):
    """p with every directory above it resolved physically (so `link/..` is the link target's
    parent), as rm does; the last component is not followed unless p ends in a slash."""
    if p.endswith("/"):
        return os.path.realpath(p)
    return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))


def braces(s):
    """The words a bash brace list (`a{b,c}d`) expands to; a brace with no top-level comma is text."""
    for i, ch in enumerate(s):
        if ch != "{":
            continue
        depth, cuts = 0, []
        for j in range(i, len(s)):
            depth += {"{": 1, "}": -1}.get(s[j], 0)
            if depth == 1 and s[j] == ",":
                cuts.append(j)
            elif depth == 0:
                if not cuts:
                    break
                bounds = [i] + cuts + [j]
                return [w for a, b in zip(bounds, bounds[1:]) for w in braces(s[:i] + s[a + 1 : b] + s[j + 1 :])]
    return [s]


def live_ids():
    """{session id: a pid carrying it} for every process of this user."""
    if "live" not in STATE:
        live, uid = {}, os.getuid()
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                if os.stat("/proc/" + pid).st_uid != uid:
                    continue
                with open("/proc/%s/environ" % pid, "rb") as f:
                    env = f.read().split(b"\0")
            except OSError:
                continue
            for kv in env:
                for var in ID_VARS:
                    if kv.startswith(var) and len(kv) > len(var):
                        live.setdefault(kv[len(var):].decode(errors="replace"), pid)
        STATE["live"] = live
    return STATE["live"]


def comm(pid):
    try:
        with open("/proc/%s/comm" % pid) as f:
            return f.read().strip()
    except OSError:
        return "gone"


def owner_dirs(target, cache):
    """The <cache>/<tool>/<id> dirs an rm -r of target removes or reaches into."""
    if target == cache or cache.startswith(target.rstrip("/") + "/"):
        return glob.glob(os.path.join(glob.escape(cache), "*", "*"))
    rel = os.path.relpath(target, cache)
    if rel.startswith(".."):
        return []
    parts = rel.split(os.sep)
    if len(parts) == 1:
        return glob.glob(os.path.join(glob.escape(target), "*"))
    return [os.path.join(cache, parts[0], parts[1])]


def recursive_flag(a):
    """-r, -R or a cluster holding one, and --recursive or any prefix GNU rm takes for it (--r...)."""
    if a.startswith("--"):
        return len(a) > 2 and "--recursive".startswith(a)
    return bool(RECURSIVE.fullmatch(a))


def targets(argv, cwd):
    """The paths rm argv names, braces and globs expanded, resolved against cwd as rm resolves
    them; None for a non-recursive rm. A word the hook cannot see ($var unset, $(...)) is skipped."""
    args, recursive, opts = [], False, True
    for a in argv[1:]:
        if opts and a == "--":
            opts = False
        elif opts and a.startswith("-") and a != "-":
            recursive = recursive or recursive_flag(a)
        else:
            args.append(a)
    if not recursive:
        return None
    out = []
    for word in args:
        for a in braces(word):
            p = os.path.expandvars(os.path.expanduser(a))
            if "$" in p or (cwd is None and not os.path.isabs(p)):
                continue
            p = os.path.join(cwd or "/", p)
            out.extend(as_rm_sees(x) for x in (sorted(glob.glob(p)) if glob.has_magic(p) else [p]))
    return out


def check(head, argv, env, cwd):
    if head != "rm":
        return None
    for t in targets(argv, cwd) or ():
        if os.path.dirname(t) == "/":
            return ROOT_MSG.format(target=t)
        for cache in cache_roots():
            for d in owner_dirs(t, cache):
                sid = os.path.basename(d)
                if sid == STATE.get("me") or not os.path.isdir(d):
                    continue
                pid = live_ids().get(sid)
                if pid:
                    return MSG.format(target=t, victim=d, sid=sid, pid=pid, comm=comm(pid))
    return None


def main():
    global FORGE
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not re.search(r"(?<![\w.-])rm(?![\w.-])", cmd):
        return
    FORGE = _forge()
    STATE["me"] = data.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CODEX_THREAD_ID")
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
