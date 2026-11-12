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


DELETED = "deleted"


def upstream(root, present, gone):
    """Path -> [mode, blob] (or DELETED) on the remote's default branch, or None with no such ref.

    A changed path whose content now matches it, or a gone path that branch deleted, came in
    from upstream (a merge of the default branch, or agent-land's fast-forward of the main
    checkout), not from this session. A gone path the branch never deleted is the session's.
    Only the changed paths are read, in batches, so a large tree costs nothing.
    """
    for ref in ("origin/HEAD", "origin/main", "origin/master"):
        try:
            git(root, "rev-parse", "--verify", "-q", ref + "^{tree}")
        except subprocess.CalledProcessError:
            continue
        tree = {}
        for i in range(0, len(present), 500):
            rows = git(root, "--literal-pathspecs", "ls-tree", "-z", "--full-tree", ref, "--", *present[i:i + 500])
            for row in rows.split(b"\0"):
                if row:
                    meta, path = row.split(b"\t", 1)
                    mode, _, blob = meta.decode().split()
                    tree[os.fsdecode(path)] = [mode, blob]
        for i in range(0, len(gone), 500):
            rows = git(root, "--literal-pathspecs", "log", "-z", "--format=", "--name-only",
                       "--diff-filter=D", ref, "--", *gone[i:i + 500])
            for name in filter(None, rows.split(b"\0")):
                name = os.fsdecode(name.strip(b"\n"))
                if name in gone and name not in tree:
                    tree[name] = DELETED
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
        tree = upstream(root, [p for p in changed if p in current], [p for p in changed if p not in current]) if changed else None
        for path in changed:
            if tree is not None and tree.get(path) == (current[path][:2] if path in current else DELETED):
                continue
            print(path)
    else:
        raise ValueError("unknown action")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError):
        sys.exit(1)
