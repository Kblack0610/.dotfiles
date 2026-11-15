#!/usr/bin/env python3
"""PreToolUse(Bash) guard: a python file write that Edit or Write would make one-for-one is denied.

The Edit/Write guards (manual-mode-investigate before, ai-comment-guard and context-budget-guard
after) match those tools only, and settings.json allows all of Bash, so a python heredoc that
patches a file skips every one of them. Usage-cleanup pass 6 (7 days to 2026-11-09) counted 11.2k
of 15k python3 calls as `open().read().replace()` patches (ar-2018).

The python code is each stdin heredoc (`python3 - <<'EOF'`, `python3 <<EOF`) and each `-c` payload,
found with forge-guard's walker (cd, subshells, bash -c, eval) and parsed with ast. A written path
resolves from a literal, a name assigned once, Path(...), `/`, os.path.join and expanduser.

Denied, outside scratch (/tmp, /var/tmp, /dev, $TMPDIR, ~/.cache, $XDG_CACHE_HOME):
- a text patch: the code reads a named file as text and writes it back, and calls nothing but
  open, path and plain str methods (replace, find, count...), so Edit makes the same change;
- a literal: a str constant written (mode w or x) to a named file, which is Write.
- In manual permission mode, any python write: that mode is investigate-only.
Passed: content the code computes (regex, json, joins, loops over lines), files found in a loop or
from argv (an unresolved path), bytes, appends, scripts run from a file. Not covered: sed -i,
`cat >`, tee, and python run from a script file. Fail-open: any error allows the command.
"""
import ast
import importlib.util
import json
import os
import re
import shlex
import sys
import warnings

HERE = os.path.dirname(os.path.abspath(__file__))
PYTHON = re.compile(r"python[0-9.]*$")
# Calls a patch may make and still be one Edit: file and path plumbing, plain str methods, asserts.
PATCH_FUNCS = {"open", "print", "len", "exit", "quit", "SystemExit", "AssertionError", "Path", "PurePath",
               "pathlib.Path", "sys.exit", "os.path.join", "os.path.expanduser", "os.path.abspath",
               "os.path.exists", "os.path.isfile"}
PATCH_METHODS = {"read", "read_text", "write", "write_text", "replace", "count", "find", "rfind", "index",
                 "close", "seek", "truncate", "expanduser", "resolve", "absolute", "exists", "is_file",
                 "startswith", "endswith", "encode", "decode"}
PATH_CALLS = {"Path", "PurePath", "PosixPath", "pathlib.Path", "pathlib.PurePath", "pathlib.PosixPath"}
SAME_PATH = {"os.path.expanduser", "os.path.abspath", "os.path.realpath", "os.path.normpath"}

EDIT_MSG = (
    "python-write-guard: this python {what} {path}, a change {tool} makes one-for-one, so the Edit/Write "
    "guards (ai-comment-guard, context-budget-guard, manual-mode-investigate) never see it. Use {tool}: "
    "Edit takes old_string/new_string (replace_all for a repeated string), Write takes the whole text. "
    "Python still passes when it computes the content (regex, json, generated text), changes files it "
    "finds in a loop, or writes scratch (/tmp, ~/.cache)."
)
MANUAL_MSG = (
    "python-write-guard: manual mode is investigate-only, and this python writes {path}. Answer without "
    "changing anything; output under /tmp or ~/.cache passes. The human switches mode (Shift+Tab) to "
    "allow edits."
)


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def is_python_code(words):
    """True when words (a simple command) run python on code from stdin: no script, -c or -m."""
    i = next((j for j, w in enumerate(words) if PYTHON.match(os.path.basename(w))), None)
    if i is None:
        return False
    for w in words[i + 1:]:
        if w == "-":
            return True
        if not w.startswith("-") or re.fullmatch(r"-[A-Za-z]*[cm][A-Za-z]*", w):
            return False
    return True


def codes(cmd, cwd, forge, poll):
    """(code, cwd) for each python heredoc and -c payload in cmd, cwd as the walker tracks it."""
    found = []

    def pythons(text):
        """(argv, cwd) of each python command the walker reaches in text; none when shlex
        cannot split it (an unbalanced quote), so the heredocs are still read."""
        seen = []

        def check(head, argv, env, d):
            if PYTHON.match(head):
                seen.append((argv, d))

        try:
            forge.reason(text, cwd, check)
        except ValueError:
            return []
        return seen

    for argv, d in pythons(cmd):
        c = next((j for j, a in enumerate(argv[1:], 1) if re.fullmatch(r"-[A-Za-z]*c", a)), None)
        if c is not None and c + 1 < len(argv):
            found.append((argv[c + 1], d))

    lines, end, q = cmd.split("\n"), None, None
    for i, line in enumerate(lines):
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        flags, q = poll.quote_flags(line, q)
        m = next((m for m in poll.HEREDOC.finditer(line) if not flags[m.start()]), None)
        if not m:
            continue
        end = m.group(2)
        before = re.split(r"[;&|(]", line[:m.start()])[-1]
        try:
            words = shlex.split(before)
        except ValueError:
            continue
        if not is_python_code(words):
            continue
        body = []
        for b in lines[i + 1:]:
            if b.strip() == end:
                break
            body.append(b)
        at = pythons(poll.strip_heredocs("\n".join(lines[:i + 1])))
        found.append(("\n".join(body), at[-1][1] if at else cwd))
    return found


def dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        base = dotted(node.value)
        return base and base + "." + node.attr
    return None


class Writes:
    """Each file write in a parsed module: (path or None, content node or None, mode)."""

    def __init__(self, tree):
        self.tree = tree
        stores, self.values = {}, {}
        for n in ast.walk(tree):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                stores[n.id] = stores.get(n.id, 0) + 1
            if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                self.values[n.targets[0].id] = n.value
        self.values = {k: v for k, v in self.values.items() if stores.get(k) == 1}

    def path(self, node, depth=0):
        """The path node names, or None when the code computes it."""
        if depth > 20:
            return None
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Name) and node.id in self.values:
            return self.path(self.values[node.id], depth + 1)
        if isinstance(node, ast.JoinedStr):
            parts = []
            for v in node.values:
                p = (v.value if isinstance(v, ast.Constant) else
                     self.path(v.value, depth + 1) if v.conversion == -1 and v.format_spec is None else None)
                if p is None:
                    return None
                parts.append(p)
            return "".join(parts)
        if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Div, ast.Add)):
            a, b = self.path(node.left, depth + 1), self.path(node.right, depth + 1)
            if a is None or b is None:
                return None
            return os.path.join(a, b) if isinstance(node.op, ast.Div) else a + b
        if isinstance(node, ast.Call) and not node.keywords:
            name = dotted(node.func)
            if name == "Path.home" or name == "pathlib.Path.home":
                return "~"
            args = [self.path(a, depth + 1) for a in node.args]
            if None in args:
                return None
            if name in PATH_CALLS or name == "os.path.join":
                return os.path.join(*args) if args else "."
            if name in SAME_PATH and len(args) == 1:
                return args[0]
            if isinstance(node.func, ast.Attribute) and node.func.attr in ("expanduser", "resolve", "absolute") and not args:
                return self.path(node.func.value, depth + 1)
        return None

    @staticmethod
    def mode(call, at):
        """The mode of an open call (mode at positional index at), or None when not a constant."""
        m = call.args[at] if len(call.args) > at else next((k.value for k in call.keywords if k.arg == "mode"), None)
        if m is None:
            return "r"
        return m.value if isinstance(m, ast.Constant) and isinstance(m.value, str) else None

    def opened(self, node):
        """(path, mode) when node is open(P, mode) or P.open(mode), else None."""
        if not isinstance(node, ast.Call):
            return None
        if isinstance(node.func, ast.Name) and node.func.id == "open" and node.args:
            return self.path(node.args[0]), self.mode(node, 1)
        if isinstance(node.func, ast.Attribute) and node.func.attr == "open":
            return self.path(node.func.value), self.mode(node, 0)
        return None

    def scan(self):
        """(writes, read paths, calls only a patch makes)."""
        handles, writes, reads, patchy = {}, [], set(), True
        for n in ast.walk(self.tree):
            items = n.items if isinstance(n, ast.With) else []
            pairs = [(i.context_expr, i.optional_vars) for i in items]
            if isinstance(n, ast.Assign) and len(n.targets) == 1:
                pairs.append((n.value, n.targets[0]))
            for expr, var in pairs:
                o = self.opened(expr)
                if o and isinstance(var, ast.Name):
                    handles[var.id] = o
        for n in ast.walk(self.tree):
            if not isinstance(n, ast.Call):
                continue
            name, attr = dotted(n.func), n.func.attr if isinstance(n.func, ast.Attribute) else None
            if name not in PATCH_FUNCS and attr not in PATCH_METHODS:
                patchy = False
            o = self.opened(n)
            if o:
                p, mode = o
                if mode is None or set(mode) & set("wax+"):
                    writes.append((p, None, mode or "w"))
                if mode is not None and (not set(mode) & set("wax") or "+" in mode) and p is not None:
                    reads.add(p)
                continue
            if attr in ("read_text", "read_bytes"):
                p = self.path(n.func.value)
                if p is not None:
                    reads.add(p)
            elif attr in ("write_text", "write_bytes"):
                writes.append((self.path(n.func.value), n.args[0] if n.args else None,
                               "w" if attr == "write_text" else "wb"))
            elif attr == "write" and n.args:
                recv = n.func.value
                o = self.opened(recv) or (handles.get(recv.id) if isinstance(recv, ast.Name) else None)
                if o and (o[1] is None or set(o[1]) & set("wax+")):
                    writes.append((o[0], n.args[0], o[1] or "w"))
        # An open whose handle the code also .write()s is counted once, at its .write.
        written = {p for p, c, _ in writes if c is not None}
        writes = [w for w in writes if w[1] is not None or w[0] not in written]
        return writes, reads, patchy


def absolute(p, cwd):
    p = os.path.expanduser(p)
    if not os.path.isabs(p):
        if not cwd:
            return p
        p = os.path.join(cwd, p)
    return os.path.normpath(p)


def scratch(p):
    roots = ["/tmp", "/var/tmp", "/dev", os.path.expanduser("~/.cache")]
    roots += [os.environ[k] for k in ("TMPDIR", "XDG_CACHE_HOME") if os.environ.get(k)]
    if not os.path.isabs(p):
        return False
    for cand in {p, os.path.realpath(p)}:
        for r in roots:
            for root in {os.path.normpath(r), os.path.realpath(r)}:
                if cand == root or cand.startswith(root.rstrip("/") + "/"):
                    return True
    return False


def literal(node):
    if isinstance(node, ast.Constant):
        return isinstance(node.value, str)
    return isinstance(node, ast.JoinedStr) and all(isinstance(v, ast.Constant) for v in node.values)


def verdict(code, cwd, manual):
    """The deny reason for one block of python code, or None."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")  # an invalid escape in the agent's code is not ours to print
            tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return None
    writes, reads, patchy = Writes(tree).scan()
    reads = {absolute(r, cwd) for r in reads}
    for p, content, mode in writes:
        target = absolute(p, cwd) if p is not None else None
        if target is not None and scratch(target):
            continue
        if manual:
            return MANUAL_MSG.format(path=target or "a file it computes")
        if target is None or "b" in mode or "a" in mode or content is None:
            continue
        if target in reads and patchy:
            return EDIT_MSG.format(what="patches", path=target, tool="Edit")
        if literal(content) and "+" not in mode:
            return EDIT_MSG.format(what="writes a literal string to", path=target, tool="Write")
    return None


def reason(cmd, cwd, manual):
    forge = _load("forge_guard", "forge-guard.py")
    poll = _load("block_poll", "block-poll.py")
    for code, d in codes(cmd, cwd, forge, poll):
        r = verdict(code, d, manual)
        if r:
            return r
    return None


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if "python" not in cmd or not any(w in cmd for w in ("open(", "write_text", "write_bytes")):
        return
    r = reason(cmd, data.get("cwd") or os.getcwd(), data.get("permission_mode") == "default")
    if r:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": r}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
