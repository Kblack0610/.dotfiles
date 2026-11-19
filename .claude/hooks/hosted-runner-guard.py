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
`<owner>/<repo>:<path>` (each with why), an origin that is not github.com (a Forgejo
`ubuntu-latest` is that forge's own runner label, not a bill), a public repo (`gh repo view`: hosted
minutes are free there, and a self-hosted runner would run a fork PR's code on the LAN), and every
other file. A failed visibility lookup counts as private, so the deny stands. An edit that
keeps a label already in the file is denied too: touching a hosted job means moving it. Not covered:
Bash writes (sed, cat >) and other agents; the org's Actions budget at $0 with prevent-further-usage
is the backstop GitHub enforces. Fail-open, like the sibling guards: any error allows the edit.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORKFLOW = re.compile(r"(^|/)\.github/workflows/[^/]+\.ya?ml$")
# Larger and suffixed images too: macos-14-large, macos-13-xlarge, ubuntu-24.04-arm, ubuntu-latest-4-cores.
HOSTED = re.compile(r"(?<![\w.-])(?:ubuntu|windows|macos)-(?:latest|slim|\d[\w.]*)(?:-\w+)*(?![\w.-])")
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


def is_github(url):
    """forge-guard's host check, which resolves an ssh Host alias (ssh -G, 2 s)."""
    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.is_github(url)


def origin(path):
    """(owner, repo, origin url, path relative to the checkout root) for the checkout holding path.

    1 s per git call, ssh -G 2 s and public() 2 s stay under the hook's 8 s timeout."""
    d = os.path.dirname(path)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    top = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=1)
    url = subprocess.run(["git", "-C", d, "config", "--get", "remote.origin.url"], capture_output=True, text=True, timeout=1)
    m = OWNER.search(url.stdout.strip())
    if top.returncode or not m:
        return None
    return m.group(1), m.group(2), url.stdout.strip(), os.path.relpath(path, top.stdout.strip())


def public(slug):
    """True only when gh says the repo is public; any failure (offline, no auth, timeout) is False."""
    try:
        out = subprocess.run(["gh", "repo", "view", slug, "--json", "visibility", "-q", ".visibility"],
                             capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0 and out.stdout.strip() == "PUBLIC"


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
    where = origin(os.path.realpath(path))
    if not where:
        return
    owner, repo, url, rel = where
    if owner.lower() not in {o.lower() for o in cfg.get("self_hosted_only", [])} or not is_github(url):
        return
    if f"{owner}/{repo}:{rel}".lower() in {k.lower() for k in cfg.get("allow", {})}:
        return
    if public(f"{owner}/{repo}"):
        return
    reason = MSG.format(repo=f"{owner}/{repo}", path=rel, label=hit.group(0))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
