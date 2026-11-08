#!/usr/bin/env python3
"""PreToolUse(Read|Bash) guard: deny a whole-file read of a file over 2,000 lines.

A Read with no limit returns a 2,000-line page, and a bare `cat` returns the whole file, and the
session then carries that output in every request after it. Usage-cleanup pass 6 (2026-11-06):
732 Reads with no limit and 312 whole-file cats returned over 20K chars each, 2% of all context.
The hint this replaced (large-file-warning.sh, additionalContext on the same Read) fired 362 times
in 7 days and changed nothing, because it arrived with the page it warned about.

Denied: a Read with no `limit` of a text file over 2,000 lines, and a `cat` whose output reaches
the context (not piped, not redirected) of such a file. Allowed: a Read with a limit, a cat piped
into another command, binary files, and anything the guard cannot stat. Out of scope: other
dumpers (`sed p`, `tail -n +1`, `echo "$(cat f)"`) and a cwd changed by anything but a plain
`cd <dir>` earlier in the command. Fail-open on any error.
"""
import json
import os
import re
import shlex
import sys

MAX_LINES = 2000
CHUNK = 1 << 16
MAX_SCAN = 8 << 20  # bytes; a file with few newlines is not scanned past this, inside the 5s hook timeout
BINARY_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".pdf", ".ipynb", ".zip", ".gz",
    ".tar", ".so", ".o", ".bin", ".wasm", ".mp3", ".mp4", ".wav", ".ttf", ".otf", ".woff", ".woff2",
}
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_]\w*)\1")
SEGMENT_END = {";", ";;", "&&", "||", "&", "(", ")", "{", "}"}
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "time"}
# Operators that send stdout to a file; stderr (2>) and dups (2>&1, >&2) still reach the context.
STDOUT_OPS = {">", ">>", ">|", "&>", "&>>"}

READ_MSG = (
    "large-read-guard: {path} has {lines}+ lines, past Read's 2,000-line page, and the session "
    "re-sends whatever it reads on every later request. Find the part you need first "
    "(`rg -n -C 8 <symbol> {path}`), then Read it with offset and limit. To read the first page "
    "anyway, call Read again with limit set."
)
CAT_MSG = (
    "large-read-guard: `cat` prints all of {path} ({lines}+ lines) into the context, and the "
    "session re-sends it on every later request. Print only the part you need: "
    "`rg -n -C 8 <symbol> {path}`, `sed -n '<a>,<b>p' {path}` or `head -n <N> {path}`."
)


def long_text(path):
    """The file's line count when it is a text file over MAX_LINES lines, else 0."""
    if os.path.splitext(path)[1].lower() in BINARY_EXT or not os.path.isfile(path):
        return 0
    lines = scanned = 0
    with open(path, "rb") as f:
        first = True
        while scanned < MAX_SCAN:
            buf = f.read(CHUNK)
            scanned += len(buf)
            if not buf:
                return 0
            if first and b"\0" in buf[:8192]:
                return 0
            first = False
            lines += buf.count(b"\n")
            if lines > MAX_LINES:
                return MAX_LINES
    return 0


def strip_heredocs(cmd):
    """The command without heredoc bodies, which are data, not commands."""
    out, end = [], None
    for line in cmd.split("\n"):
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        m = HEREDOC.search(line)
        if m:
            end = m.group(2)
        out.append(line)
    return "\n".join(out)


def cat_targets(cmd, cwd):
    """(shown, path) for each file a `cat` prints into the context: not piped on, its stdout not
    sent to a file, not inside `$(...)`. A plain `cd <dir>` earlier in the command moves cwd."""
    # A newline ends a command and a comment: it becomes the `;;` token, which nothing else here uses.
    text = strip_heredocs(cmd).replace("\\\n", " ").replace("\n", " ;; ")
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    segments, cur, captured, prev, comment = [], [], False, "", False
    for tok in lex:
        if comment and tok != ";;":
            continue
        comment = False
        if tok.startswith("#"):
            comment = True
            continue
        if tok in SEGMENT_END:
            segments.append((captured, cur))
            # `$(...)` captures what runs inside it; it does not print it.
            captured, cur = tok == "(" and prev.endswith("$"), []
        else:
            cur.append(tok)
        prev = tok
    segments.append((captured, cur))
    out = []
    for captured, seg in segments:
        while seg and (seg[0] in KEYWORDS or ("=" in seg[0] and not seg[0].startswith("="))):
            seg = seg[1:]
        if not seg or captured:
            continue
        if seg[0] == "cd" and len(seg) == 2:
            cwd = os.path.join(cwd, os.path.expanduser(seg[1]))
            continue
        if os.path.basename(seg[0]) != "cat" or "|" in seg or "|&" in seg:
            continue
        files, to_file, i = [], False, 1
        while i < len(seg):
            t = seg[i]
            fd = ""
            if t.isdigit() and i + 1 < len(seg) and seg[i + 1][:1] in "<>":
                fd, i = t, i + 1
                t = seg[i]
            if t in STDOUT_OPS and fd in ("", "1"):
                to_file = True
            if t == "<" and i + 1 < len(seg):
                files.append(seg[i + 1])
            if t[:1] in "<>" or t in STDOUT_OPS:
                i += 2
                continue
            if not t.startswith("-"):
                files.append(t)
            i += 1
        if not to_file:
            out.extend((f, os.path.join(cwd, os.path.expanduser(f))) for f in files)
    return out


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))


def main():
    data = json.load(sys.stdin)
    tool = data.get("tool_name")
    tin = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    if tool == "Read":
        path = tin.get("file_path") or ""
        if path and tin.get("limit") is None:
            lines = long_text(path)
            if lines:
                deny(READ_MSG.format(path=path, lines=lines))
    elif tool == "Bash" and not tin.get("run_in_background"):
        for arg, path in cat_targets(tin.get("command") or "", cwd):
            lines = long_text(path)
            if lines:
                return deny(CAT_MSG.format(path=arg, lines=lines))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
