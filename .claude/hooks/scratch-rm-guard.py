#!/usr/bin/env python3
"""PreToolUse(Bash) guard: an rm -r may not remove another live session's cache scratch.

A session keeps large scratch in ~/.cache/<tool>/<session-id>/ (global CLAUDE.md, scratch rule),
so a whole ~/.cache/<tool> dir can hold several sessions' work. 2026-11-10 16:54: session 207ca085
ran an rm -rf of ~/.cache/hub-spend-history and killed session 71d86bf6's backfill and its
original-snapshot copies, kept in its own <session-id> subdir there.

Denied: an `rm` with -r, -R or --recursive whose target is, holds, or sits inside a
<cache>/<tool>/<id> directory, where <id> is the session id of a live session other than the
caller's. <cache> is $XDG_CACHE_HOME or ~/.cache. A session is live while a process of this user
carries its id in CLAUDE_CODE_SESSION_ID (Claude) or CODEX_THREAD_ID (Codex); the caller is the hook
input's session_id. The caller's own <id> dir, a dir no live session owns, and files by name pass.
Each command is walked with forge-guard's walker (cd, subshells, bash -c, eval); a glob target is
expanded. Not covered: find -delete, xargs, rm of a shell variable the hook cannot see, rmtree
from a script. Fail-open: any error allows the command.
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
    "scratch-rm-guard: `rm -r {target}` would remove {victim}, the scratch of live session {sid} "
    "(pid {pid}), and kill its work. Remove only your own {cache}/<tool>/<your session id>/ or the "
    "files you wrote, by name; if that session is gone, its processes are still running."
)


def _forge():
    import importlib.util

    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FORGE = None  # loaded past main's prefilter: this hook runs on every Bash call
STATE = {}  # cache root, caller id, live ids (read once, on first need)


def cache_root():
    return os.path.realpath(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"))


def as_rm_sees(p):
    """p with every directory above it resolved: rm follows those links but not the last one."""
    return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))


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


def targets(argv, cwd):
    """The paths rm argv names, resolved against cwd, globs expanded; None for a non-recursive rm."""
    args, recursive, opts = [], False, True
    for a in argv[1:]:
        if opts and a == "--":
            opts = False
        elif opts and a.startswith("-") and a != "-":
            recursive = recursive or a == "--recursive" or bool(RECURSIVE.fullmatch(a))
        else:
            args.append(a)
    if not recursive:
        return None
    out = []
    for a in args:
        p = FORGE.resolve(cwd, a)
        if p is None:
            continue
        out.extend(as_rm_sees(x) for x in (sorted(glob.glob(p)) if glob.has_magic(p) else [p]))
    return out


def check(head, argv, env, cwd):
    if head != "rm":
        return None
    cache = cache_root()
    for t in targets(argv, cwd) or ():
        for d in owner_dirs(t, cache):
            sid = os.path.basename(d)
            if sid == STATE.get("me") or not os.path.isdir(d):
                continue
            pid = live_ids().get(sid)
            if pid:
                return MSG.format(target=t, victim=d, sid=sid, pid=pid, cache=cache)
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
