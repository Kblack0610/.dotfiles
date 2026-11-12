#!/usr/bin/env python3
"""Snapshot session-start file state; print paths changed since that snapshot."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)


def state(root, before=None):
    # Index blob ids avoid reading every clean tracked file on each Stop.
    files = {}
    for row in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not row:
            continue
        meta, path = row.split(b"\t", 1)
        mode, blob, stage = meta.decode().split()
        files[os.fsdecode(path)] = [mode, blob, stage, None]
    dirty = git(root, "diff", "--name-only", "-z") + git(root, "ls-files", "--others", "--exclude-standard", "-z")
    for name in set(filter(None, dirty.split(b"\0"))):
        path = root / os.fsdecode(name)
        if not path.exists() and not path.is_symlink():
            files.pop(os.fsdecode(name), None)
            continue
        info = path.lstat()
        metadata = [info.st_size, info.st_mtime_ns, info.st_ctime_ns]
        previous = (before or {}).get(os.fsdecode(name))
        if previous and previous[3] == metadata:
            files[os.fsdecode(name)] = previous
            continue
        if path.is_symlink():
            data, mode = os.fsencode(os.readlink(path)), "120000"
            digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0")
            digest.update(data)
        elif path.is_file():
            mode = "100755" if info.st_mode & 0o111 else "100644"
            digest = hashlib.sha1(b"blob " + str(info.st_size).encode() + b"\0")
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            continue
        files[os.fsdecode(name)] = [mode, digest.hexdigest(), "0", metadata]
    return files


def upstream(root):
    """Path -> [mode, blob] on the remote's default branch, or None when there is none.

    A path whose state now matches it came in from upstream (another session's PR, pulled
    by a merge or by agent-land's fast-forward of the main checkout), not from this session.
    2026-11-11 (ar-1652): one landed SKILL.md made every open session in the repo re-run
    its picked bats files at each Stop, on a box already at load 2.6x.
    """
    for ref in ("origin/HEAD", "origin/main", "origin/master"):
        try:
            rows = git(root, "ls-tree", "-r", "-z", "--full-tree", ref + "^{tree}")
        except subprocess.CalledProcessError:
            continue
        tree = {}
        for row in rows.split(b"\0"):
            if row:
                meta, path = row.split(b"\t", 1)
                mode, _, blob = meta.decode().split()
                tree[os.fsdecode(path)] = [mode, blob]
        return tree
    return None


def main():
    action, directory, sid = sys.argv[1:]
    root = Path(os.fsdecode(git(directory, "rev-parse", "--show-toplevel")).strip())
    key = hashlib.sha256((str(root) + "\0" + sid).encode()).hexdigest()
    cache = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "claude-stop-hook"
    baseline = cache / ("session-start-" + key + ".json")
    if action == "start":
        if not baseline.exists():
            current = state(root)
            cache.mkdir(parents=True, exist_ok=True)
            with baseline.open("x") as stream:
                json.dump(current, stream)
    elif action == "changed":
        before = json.loads(baseline.read_text())
        current = state(root, before)
        changed = [p for p in sorted(before.keys() | current.keys())
                   if (before.get(p) or [])[:3] != (current.get(p) or [])[:3]]
        tree = upstream(root) if changed else None
        for path in changed:
            if tree is not None and (current.get(path) or [None, None])[:2] == tree.get(path, [None, None]):
                continue
            print(path)
    else:
        raise ValueError("unknown action")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError):
        sys.exit(1)
