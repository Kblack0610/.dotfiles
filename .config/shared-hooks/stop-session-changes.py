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


# The baseline's HEAD at session start; a path never holds a NUL, so the key cannot collide.
HEAD = "\0head"


def default_ref(root):
    """The remote's default branch (origin/HEAD, else origin/main or origin/master), or None."""
    for ref in ("origin/HEAD", "origin/main", "origin/master"):
        try:
            git(root, "rev-parse", "--verify", "-q", ref + "^{tree}")
            return ref
        except subprocess.CalledProcessError:
            continue
    return None


def ls_tree(root, rev, paths):
    """Path -> [mode, blob] for the paths rev holds, read in batches: cost follows the paths, not the tree."""
    tree = {}
    for i in range(0, len(paths), 500):
        rows = git(root, "--literal-pathspecs", "ls-tree", "-z", "--full-tree", rev, "--", *paths[i:i + 500])
        for row in filter(None, rows.split(b"\0")):
            meta, path = row.split(b"\t", 1)
            mode, _, blob = meta.decode().split()
            tree[os.fsdecode(path)] = [mode, blob]
    return tree


def upstream(root, head, changed, current):
    """The changed paths that came in from the default branch, not from this session.

    A merge of the default branch, or agent-land's fast-forward of the main checkout, brings
    in its files. A path counts as upstream's when its content now matches that branch, or
    when it is gone, that branch lacks it, and the fork point of the session's starting HEAD
    and that branch held it. A baseline with no HEAD counts every deletion.
    """
    ref = default_ref(root)
    if ref is None:
        return set()
    tree = ls_tree(root, ref, changed)
    theirs = {p for p in changed if p in current and tree.get(p) == current[p][:2]}
    gone = [p for p in changed if p not in current and p not in tree]
    if head and gone:
        try:
            base = git(root, "merge-base", head, ref).decode().strip()
        except subprocess.CalledProcessError:
            base = None
        if base:
            theirs |= ls_tree(root, base, gone).keys()
    return theirs


def main():
    action, directory, sid = sys.argv[1:]
    root = Path(os.fsdecode(git(directory, "rev-parse", "--show-toplevel")).strip())
    key = hashlib.sha256((str(root) + "\0" + sid).encode()).hexdigest()
    cache = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "claude-stop-hook"
    baseline = cache / ("session-start-" + key + ".json")
    if action == "start":
        if not baseline.exists():
            current = state(root)
            try:
                current[HEAD] = git(root, "rev-parse", "--verify", "-q", "HEAD").decode().strip()
            except subprocess.CalledProcessError:
                pass
            cache.mkdir(parents=True, exist_ok=True)
            with baseline.open("x") as stream:
                json.dump(current, stream)
    elif action == "changed":
        before = json.loads(baseline.read_text())
        head = before.pop(HEAD, None)
        current = state(root, before)
        changed = [p for p in sorted(before.keys() | current.keys())
                   if (before.get(p) or [])[:3] != (current.get(p) or [])[:3]]
        theirs = upstream(root, head, changed, current) if changed else set()
        for path in changed:
            if path not in theirs:
                print(path)
    else:
        raise ValueError("unknown action")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError):
        sys.exit(1)
