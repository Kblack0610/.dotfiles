#!/usr/bin/env python3
"""PreToolUse(Edit|Write|MultiEdit) guard: no GitHub-hosted runner in a personal repo's workflow.

Personal GitHub owners run Actions only on our self-hosted runners (org vars LINUX_RUNNER_LIGHT and
LINUX_RUNNER_HEAVY, the Unity and macOS slot labels), so GitHub bills them nothing. 2026-11-17: the
studio org paid $31 in hosted Linux minutes in 17 days from jobs that hard-coded
`ubuntu-latest` or `ubuntu-24.04` (unity-core-harness Package Tests, about 25 platform workflows,
playground steam.yml), next to `vars.LINUX_RUNNER_LIGHT || '"ubuntu-latest"'` fallbacks that bill the
moment a var is unset (queue item gh-actions-zero).

Denied: an edit or write of `.github/workflows/*.yml|yaml` in a checkout whose origin owner is listed
in project-map.json `github_runners.self_hosted_only`, when the text it writes names a GitHub-hosted
image label (`ubuntu-*`, `windows-*`, `macos-*` with latest, slim or a version) outside a comment.
Passed: owners not listed (work orgs), a workflow listed in `github_runners.allow` as
`<owner>/<repo>:<path>` (each with why), and every other file. Not covered: Bash writes (sed, cat >)
and other agents; the org's Actions budget at $0 with prevent-further-usage is the backstop GitHub
enforces. Fail-open: any error allows the edit.
"""
import json
import os
import re
import subprocess
import sys

WORKFLOW = re.compile(r"(^|/)\.github/workflows/[^/]+\.ya?ml$")
HOSTED = re.compile(r"(?<![\w.-])(?:ubuntu|windows|macos)-(?:latest|slim|\d[\w.]*)(?:-arm)?(?![\w.-])")
COMMENT = re.compile(r"(^|\s)#.*$")
OWNER = re.compile(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$")

MSG = (
    "hosted-runner-guard: {repo} runs Actions only on our self-hosted runners, and {path} would get "
    "the GitHub-hosted label `{label}`, which GitHub bills. Use `runs-on: ${{{{ fromJSON(vars.LINUX_RUNNER_LIGHT) }}}}` "
    "(LINUX_RUNNER_HEAVY for a heavy job, the playground's unity slot labels for a Unity job, "
    "`[self-hosted, macOS]` for a Mac job), with no `|| '\"ubuntu-latest\"'` fallback. A workflow that "
    "truly needs a GitHub-hosted machine is listed, with why, under `github_runners.allow` in "
    "~/.config/shared-hooks/project-map.json (private dotfiles)."
)


def config():
    path = os.environ.get("PROJECT_MAP_FILE") or os.path.expanduser("~/.config/shared-hooks/project-map.json")
    with open(path) as f:
        return json.load(f).get("github_runners") or {}


def origin(path):
    """(owner, repo, path relative to the checkout root) for the checkout holding path."""
    d = os.path.dirname(path)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    top = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=3)
    url = subprocess.run(["git", "-C", d, "remote", "get-url", "origin"], capture_output=True, text=True, timeout=3)
    m = OWNER.search(url.stdout.strip())
    if top.returncode or not m:
        return None
    return m.group(1), m.group(2), os.path.relpath(path, top.stdout.strip())


def written(tool, ti):
    if tool == "Write":
        return ti.get("content", "")
    if tool == "Edit":
        return ti.get("new_string", "")
    return "\n".join(e.get("new_string", "") for e in ti.get("edits", []))


def main():
    payload = json.load(sys.stdin)
    ti = payload.get("tool_input") or {}
    path = ti.get("file_path") or ""
    if not WORKFLOW.search(path):
        return
    text = "\n".join(COMMENT.sub("", line) for line in written(payload.get("tool_name"), ti).splitlines())
    hit = HOSTED.search(text)
    if not hit:
        return
    cfg = config()
    where = origin(os.path.abspath(path))
    if not where:
        return
    owner, repo, rel = where
    if owner.lower() not in {o.lower() for o in cfg.get("self_hosted_only", [])}:
        return
    if f"{owner}/{repo}:{rel}".lower() in {k.lower() for k in cfg.get("allow", {})}:
        return
    reason = MSG.format(repo=f"{owner}/{repo}", path=rel, label=hit.group(0))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
