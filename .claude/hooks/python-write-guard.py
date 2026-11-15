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
from argv (an unresolved path), bytes, appends, scripts run from a file, and outside manual mode
kernel files under /proc and /sys. Not covered: sed -i,
`cat >`, tee, and python run from a script file. Fail-open: any error allows the command.
"""
import json
import os
import re
import sys

# ast, shlex and the sibling modules load past main's prefilter: this hook runs on every Bash call.
HERE = os.path.dirname(os.path.abspath(__file__))
PYTHON = re.compile(r"python[0-9.]*$")
REDIRECT = re.compile(r"\d*(?:[<>]+|&>+)")  # a whole word when its target is the next word
VIRTUAL = ("/proc/", "/sys/")  # kernel files: Edit and Write cannot make that change either
PATH_CALLS = {"Path", "PurePath", "PosixPath", "pathlib.Path", "pathlib.PurePath", "pathlib.PosixPath"}
SAME_PATH = {"os.path.expanduser", "os.path.abspath", "os.path.realpath", "os.path.normpath"}
# Calls a patch may make and still be one Edit: file and path plumbing, plain str methods, asserts.
PATCH_FUNCS = PATH_CALLS | SAME_PATH | {"open", "print", "len", "exit", "quit", "SystemExit", "AssertionError",
                                        "sys.exit", "os.path.join", "os.path.exists", "os.path.isfile"}
PATCH_METHODS = {"read", "read_text", "write", "write_text", "replace", "count", "find", "rfind", "index",
                 "close", "seek", "truncate", "expanduser", "resolve", "absolute", "exists", "is_file",
                 "startswith", "endswith", "encode", "decode"}
SCRATCH = None  # the scratch roots, normalised and resolved, built on first need

VERB = {"Edit": "patches", "Write": "writes a literal string to"}
EDIT_MSG = (
    "python-write-guard: this python {verb} {path}, a change {tool} makes one-for-one, so the Edit/Write "
    "guard hooks never see it. Use {tool}: Edit takes old_string/new_string (replace_all for a repeated "
    "string), Write takes the whole text. Python still passes when it computes the content (regex, json, "
    "generated text), changes files it finds in a loop, or writes scratch (/tmp, ~/.cache)."
)
MANUAL_MSG = (
    "python-write-guard: manual mode is investigate-only, and this python writes {path}. Answer without "
    "changing anything; output under /tmp or ~/.cache passes. The human switches mode (Shift+Tab) to "
    "allow edits."
)


def _load(name, file):
    import importlib.util

    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def source(words):
    """What the python in words (a simple command) runs: ("stdin", None), ("c", payload), or None
    for a script, -m, or no python. Options before the first non-option word are python's own."""
    i = next((j for j, w in enumerate(words) if PYTHON.match(os.path.basename(w))), None)
    if i is None:
        return None
    rest = iter(words[i + 1:])
    for w in rest:
        if w == "-":
            return "stdin", None
        if REDIRECT.match(w):
            if REDIRECT.fullmatch(w):
                next(rest, None)  # `2> file`: the file is the redirect's, not a script
            continue
        if not w.startswith("-"):
            return None
        if re.fullmatch(r"-[A-Za-z]*c", w):
            return "c", next(rest, None)
        if re.fullmatch(r"-[A-Za-z]*m[A-Za-z]*", w):
            return None
        if re.fullmatch(r"-[A-Za-z]*[WX]", w):
            next(rest, None)  # -W ignore, -X utf8: the option's value
    return "stdin", None


def codes(cmd, cwd, forge, poll):
    """(code, cwd) for each python heredoc and -c payload in cmd, cwd as the walker tracks it."""
    found = []

    def pythons(text):
        """(argv, cwd) of each command the walker reaches in text; none when shlex
        cannot split it (an unbalanced quote), so the heredocs are still read."""
        seen = []

        def check(head, argv, env, d):
            seen.append((argv, d))

        try:
            forge.reason(text, cwd, check)
        except ValueError:
            return []
        return seen

    for argv, d in pythons(cmd):
        src = source(argv)
        if src and src[0] == "c" and src[1] is not None:
            found.append((src[1], d))

    lines = cmd.split("\n")
    for i, line, m, body in poll.heredoc_lines(cmd):
        if not m:
            continue
        try:
            words = shlex.split(re.split(r"[;|(]|(?<![<>])&(?!>)", line[:m.start()])[-1])
        except ValueError:
            continue
        if source(words) == ("stdin", None):
            # The heredoc's own command is the last one the walker reaches in the prefix.
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
        if dotted(node) == "os.devnull":
            return "/dev/null"
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
            if name in ("tempfile.gettempdir", "tempfile.mkdtemp") and len(node.args) < 3:
                import tempfile
                return os.path.join(tempfile.gettempdir(), "tmp")
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
        """(writes, read paths): each write as (path or None, content node or None, mode)."""
        handles, writes, reads = {}, [], set()
        for n in ast.walk(self.tree):
            items = n.items if isinstance(n, ast.With) else []
            pairs = [(i.context_expr, i.optional_vars) for i in items]
            if isinstance(n, ast.Assign) and len(n.targets) == 1:
                pairs.append((n.value, n.targets[0]))
            for expr, var in pairs:
                o = self.opened(expr)
                if o and isinstance(var, ast.Name):
                    handles.setdefault(var.id, []).append(o)
        for n in ast.walk(self.tree):
            if not isinstance(n, ast.Call):
                continue
            attr = n.func.attr if isinstance(n.func, ast.Attribute) else None
            o = self.opened(n)
            if o:
                p, mode = o
                if writing(mode):
                    writes.append((p, None, mode or "w"))
                if p is not None and mode is not None and ("r" in mode or "+" in mode):
                    reads.add(p)
            elif attr in ("read_text", "read_bytes"):
                reads.add(self.path(n.func.value))
            elif attr in ("write_text", "write_bytes"):
                writes.append((self.path(n.func.value), n.args[0] if n.args else None,
                               "w" if attr == "write_text" else "wb"))
            elif attr == "write" and n.args:
                recv = n.func.value
                opens = [self.opened(recv)] + (handles.get(recv.id, []) if isinstance(recv, ast.Name) else [])
                o = next((o for o in opens if o and writing(o[1])), None)
                if o:
                    writes.append((o[0], n.args[0], o[1] or "w"))
        # An open whose handle the code also .write()s is counted once, at its .write.
        written = {p for p, c, _ in writes if c is not None}
        return [w for w in writes if w[1] is not None or w[0] not in written], reads - {None}


def writing(mode):
    """An open mode that writes; None (a mode the code computes) counts as one."""
    return mode is None or bool(set(mode) & set("wax+"))


def patchy(tree):
    """True when every call in tree is one a patch makes (PATCH_FUNCS, PATCH_METHODS)."""
    return all(dotted(n.func) in PATCH_FUNCS or (isinstance(n.func, ast.Attribute) and n.func.attr in PATCH_METHODS)
               for n in ast.walk(tree) if isinstance(n, ast.Call))


def scratch(p):
    global SCRATCH
    if SCRATCH is None:
        roots = ["/tmp", "/var/tmp", "/dev", os.path.expanduser("~/.cache")]
        roots += [os.environ[k] for k in ("TMPDIR", "XDG_CACHE_HOME") if os.environ.get(k)]
        SCRATCH = {f(r).rstrip("/") + "/" for r in roots for f in (os.path.normpath, os.path.realpath)}
    return any((c + "/").startswith(r) for c in (p, os.path.realpath(p)) for r in SCRATCH)


def literal(node):
    if isinstance(node, ast.Constant):
        return isinstance(node.value, str)
    return isinstance(node, ast.JoinedStr) and all(isinstance(v, ast.Constant) for v in node.values)


def verdict(code, cwd, manual, resolve):
    """The deny reason for one block of python code, or None. resolve(cwd, path) is forge-guard's:
    None for a path it cannot place."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")  # an invalid escape in the agent's code is not ours to print
            tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return None
    writes, reads = Writes(tree).scan()
    reads = {resolve(cwd, r) for r in reads}
    for p, content, mode in writes:
        if not manual and (p is None or content is None or "b" in mode or "a" in mode):
            continue
        target = resolve(cwd, p) if p is not None else None
        if target is not None and (scratch(target) or not manual and target.startswith(VIRTUAL)):
            continue
        if manual:
            return MANUAL_MSG.format(path=target or "a file it computes")
        if target is None:
            continue
        tool = ("Edit" if target in reads and patchy(tree) else
                "Write" if literal(content) and "+" not in mode else None)
        if tool:
            return EDIT_MSG.format(verb=VERB[tool], path=target, tool=tool)
    return None


def reason(cmd, cwd, manual):
    global ast, shlex, warnings
    import ast
    import shlex
    import warnings

    forge = _load("forge_guard", "forge-guard.py")
    poll = _load("block_poll", "block-poll.py")
    for code, d in codes(cmd, cwd, forge, poll):
        r = verdict(code, d, manual, forge.resolve)
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
