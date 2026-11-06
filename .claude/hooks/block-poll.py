#!/usr/bin/env python3
"""PreToolUse(Bash) guard: deny the poll shapes that spend turns on waiting.

2026-11-03/04 overnight: 738 of the heavy sessions' turns (14%) were polls, `timeout 590 bash -c
"until grep ..."` loops and `gh run watch` on top of agent-land's own wait. Each pass blocks the
turn, and each re-check re-reads the whole context. A background command wakes the session once.

Denied: `gh run watch` anywhere (it polls the API for the whole wait, unity-core-playground
docs/operations/ci.md rule 8), and a foreground loop that sleeps: `until`, `while` (not `while
read`), or a `for` that breaks out. Allowed: the same loop with run_in_background, a loop inside a
script file, a heredoc body, and text in quotes, except a `-c` payload, which is checked as code.

Also denied: a foreground read of a background task's `tasks/<id>.output` while a process still
holds that file open, i.e. the run is live and its notice has not come. 2026-11-05: 243 such reads
re-read 27.7M tokens of context. The liveness test is stop-checks.d/10-git-workflow.sh's. The same
read in the background (an `until grep` wait) and any read after the run exits are allowed.
Fail-open: any error allows the command.
"""
import json
import os
import re
import sys

SEP = r"(?:^|[;&|(){}\s])"
END = r"(?=[;&|(){}\s]|$)"
GH_WATCH = re.compile(SEP + r"gh\s+run\s+watch" + END)
KEYWORD = re.compile(SEP + r"(until|while|for)\s")
LOOP = re.compile(r"(until|while|for)\s+(.*?)" + SEP + r"do" + END + r"(.*)" + SEP + r"done" + END, re.S)
SLEEP = re.compile(SEP + r"sleep" + END)
BREAK = re.compile(SEP + r"(break|exit)" + END)
SHELL_C = re.compile(SEP + r"(?:ba|z|da|k)?sh(?:\s+-\S+)*\s+-[a-z]*c\s*$")
TASK_OUTPUT = re.compile(r"/tasks/([\w.-]+)\.output")
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_]\w*)\1")

WATCH_MSG = (
    "`gh run watch` polls the GitHub API for the whole wait and is banned (unity-core-playground "
    "docs/operations/ci.md rule 8). `agent-land <N>` already waits for a PR's checks: start the "
    "gate-and-land command with run_in_background and act on its completion notification."
)
LOOP_MSG = (
    "This foreground loop polls: it blocks the turn, and every re-check re-reads the whole "
    "context. Start the same wait with run_in_background: true (or the Monitor tool) and act on "
    "the completion notification; do not check its output, gh or git before the notice arrives. "
    "A loop inside a script file is not affected."
)
LIVE_MSG = (
    "Background task {id} is still running, so this read polls it, and every look re-reads the "
    "whole context. Act on its completion notification, then read the output once (tail -n 40). "
    "To watch a long run as it goes use the Monitor tool; to end it, TaskStop."
)


def strip_heredocs(cmd):
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


def code_texts(cmd):
    """The command with quoted text blanked, plus each `-c '<payload>'`, recursively."""
    texts, out, i, n = [], [], 0, len(cmd)
    while i < n:
        c = cmd[i]
        if c == "\\" and i + 1 < n:
            out.append(cmd[i : i + 2])
            i += 2
            continue
        if c in "'\"":
            j, body = i + 1, []
            while j < n and cmd[j] != c:
                if c == '"' and cmd[j] == "\\" and j + 1 < n:
                    body.append(cmd[j + 1])
                    j += 2
                    continue
                body.append(cmd[j])
                j += 1
            if SHELL_C.search("".join(out)):
                texts.extend(code_texts("".join(body)))
            out.append(" Q ")
            i = j + 1
            continue
        out.append(c)
        i += 1
    texts.insert(0, "".join(out))
    return texts


def polls(text):
    for k in KEYWORD.finditer(text):
        m = LOOP.match(text, k.start(1))
        if not m:
            continue
        kind, cond, body = m.group(1), m.group(2), m.group(3)
        if not SLEEP.search(body):
            continue
        if kind == "while" and re.match(r"\s*read" + END, cond):
            continue
        if kind == "for" and not BREAK.search(body):
            continue
        return True
    return False


def live_outputs(ids):
    """The ids whose tasks/<id>.output some process still holds open: the run is still going."""
    ends = {"/tasks/%s.output" % i: i for i in ids}
    live = set()
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            fds = os.listdir("/proc/%s/fd" % pid)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink("/proc/%s/fd/%s" % (pid, fd))
            except OSError:
                continue
            for end, i in ends.items():
                if target.endswith(end):
                    live.add(i)
    return live


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "block-poll: " + reason}}))


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    tin = data.get("tool_input") or {}
    texts = code_texts(strip_heredocs(tin.get("command") or ""))
    if any(GH_WATCH.search(t) for t in texts):
        return deny(WATCH_MSG)
    if tin.get("run_in_background"):
        return
    if any(polls(t) for t in texts):
        return deny(LOOP_MSG)
    ids = set(TASK_OUTPUT.findall(tin.get("command") or ""))
    live = live_outputs(ids) if ids else set()
    if live:
        return deny(LIVE_MSG.format(id=sorted(live)[0]))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
