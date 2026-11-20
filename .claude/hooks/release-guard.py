#!/usr/bin/env python3
"""PreToolUse(Bash) guard: no agent session cuts a release.

The human, 2026-11-19 (epic ucp-2709, plan pure-dreaming-kernighan): a release must be impossible
for an agent to cut. The system cuts it (`cut.yml`, started by the `release-cut` lane when the
sprint's window says so). An agent fixes and improves the release pipeline, and may re-send a cut
that already exists. Until then a coordinator answered "no release until X" with an advisory hold
that nothing read, and the `release` skill told a session to tag and dispatch.

Denied: `git tag` creating a release tag (`v<n>.<n>...`, `<name>-v<n>.<n>...`); a `git push` that
carries one, deletes one, or pushes `--tags`, `--follow-tags` or `--mirror`; `gh release create` of
a release tag not yet on origin; `gh workflow run cut.yml`; a run of a cut script
(`scripts/release/ship.sh`, `scripts/release.sh`, `scripts/publish.sh`); a `gh api` or curl write
to `rulesets`, `environments` or `keys` (the ruleset bypass, the environment secrets, the deploy
key); and the untested override (`RELEASE_UNTESTED=`, a workflow's `untested-reason` input).
Allowed: a re-send, `gh workflow run <release workflow> -f tag=<t>` (or `--ref <t>`) when every
release tag it names is already on origin, and `gh run rerun`. A release workflow dispatch that
names no release tag is denied, since it could only cut.

The command walker is forge-guard's (cd, bash -c, eval, subshells). Codex runs this hook from
`.config/codex/hooks.json`. GitHub's ruleset is the backstop once cut.yml holds the only key
(P16). Fail-open on a parse error; a tag whose presence on origin cannot be read is denied, since
the guard cannot tell a re-send from a cut.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE_TAG = re.compile(r"(?:^|-)v\d+\.\d+")
RELEASE_WORKFLOWS = {"release.yml", "phone-release.yml", "ios-release.yml", "steam.yml"}
CUT_WORKFLOWS = {"cut.yml"}
CUT_SCRIPTS = {("release", "ship.sh"), ("scripts", "release.sh"), ("scripts", "publish.sh")}
GUARDED_API = re.compile(r"/(rulesets|environments|keys)(?:/|$)")
API_PATH = re.compile(r"^(?:https?://api\.github\.com)?/?(?:repos|orgs|user|enterprises)/")
LOCKS = "change a ruleset, an environment or a key, the locks that keep the cut in cut.yml"
OVERRIDE_ENV = "RELEASE_UNTESTED"
OVERRIDE_INPUT = "untested-reason"
TAG_LIST = {"-l", "--list", "-d", "--delete", "-v", "--verify", "--contains", "--no-contains",
            "--merged", "--no-merged", "--points-at"}
TAG_OPT_ARG = {"-m", "--message", "-F", "--file", "-u", "--local-user", "--cleanup", "--trailer"}
PUSH_ALL_TAGS = {"--tags", "--follow-tags", "--mirror"}
PUSH_OPT_ARG = {"-o", "--push-option", "--receive-pack", "--exec", "--repo"}
WF_FIELD = {"-f", "--raw-field", "-F", "--field"}
WF_OPT_ARG = {"-R", "--repo", "-r", "--ref", "--json"} | WF_FIELD

WHY = ("No agent cuts a release: cut.yml cuts it when the sprint's window says so (ucp-2709, the "
       "human 2026-11-19). An agent fixes the pipeline on main and re-sends a cut that exists: "
       "`gh workflow run release.yml -f tag=<existing tag>` or `gh run rerun <id>`. The `release` "
       "skill says how.")
MSG = "release-guard: {what} would {does}. " + WHY


def _forge():
    import importlib.util

    spec = importlib.util.spec_from_file_location("forge_guard", os.path.join(HERE, "forge-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FORGE = None  # loaded past main's prefilter: this hook runs on every Bash call


def release_tag(ref):
    """True when ref names a release tag: a bare name or refs/tags/<name>, never a branch."""
    if ref.startswith("refs/") and not ref.startswith("refs/tags/"):
        return False
    return bool(RELEASE_TAG.search(ref.removeprefix("refs/tags/")))


def deny(what, does):
    return MSG.format(what="`%s`" % what, does=does)


def check_tag(argv, i):
    args = argv[i + 1 :]
    if any(a in TAG_LIST or a.startswith(("--list=", "--contains=", "--no-contains=", "--merged=", "--no-merged=", "--points-at=")) for a in args):
        return None
    j = 0
    while j < len(args):
        a = args[j]
        if a in TAG_OPT_ARG or (a[:1] == "-" and a[:2] != "--" and a[-1:] in "mFu" and len(a) > 1):
            j += 2
            continue
        if not a.startswith("-"):
            return deny("git tag %s" % a, "create a release tag") if release_tag(a) else None
        j += 1
    return None


def pushes_tag(d, side):
    """True when one side of a push refspec names a release tag. A bare name that is a local branch
    and no local tag is that branch (`fix-v1.2-bug`)."""
    if not release_tag(side):
        return False
    if side.startswith("refs/") or not d:
        return True
    return not (FORGE.git(d, "rev-parse", "-q", "--verify", "refs/heads/" + side)
                and not FORGE.git(d, "rev-parse", "-q", "--verify", "refs/tags/" + side))


def check_push(d, argv, i):
    args, pos, j = argv[i + 1 :], [], 0
    while j < len(args):
        a = args[j]
        if a in PUSH_ALL_TAGS:
            return deny("git push %s" % a, "push every local tag, release tags included")
        if a in PUSH_OPT_ARG:
            j += 2
            continue
        if not a.startswith("-"):
            pos.append(a)
        j += 1
    for k, spec in enumerate(pos[1:], 1):
        if spec == "tag" and k + 1 < len(pos):
            spec = pos[k + 1]
        if any(pushes_tag(d, side) for side in spec.lstrip("+").split(":") if side):
            return deny("git push %s" % spec, "push or delete a release tag")
    return None


def origin_has(cwd, slug, tag):
    """True when origin holds refs/tags/<tag>, False when it does not, None when it cannot tell.
    Origin is the clone of <owner>/<repo> project-map lists, else its GitHub URL, else cwd's."""
    if slug:
        clone = FORGE.clone_for(slug)
        where = (clone, "origin") if clone and os.path.isdir(clone) else (cwd, "https://github.com/%s.git" % slug)
    else:
        where = (cwd, "origin")
    try:
        r = subprocess.run(["git", "-C", where[0] or "/", "ls-remote", "--tags", where[1], "refs/tags/" + tag],
                           capture_output=True, text=True, timeout=4)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return bool(r.stdout.strip())


def missing_tags(cwd, slug, tags):
    """The first tag of tags not on origin, with why; None when all are there."""
    for t in tags:
        has = origin_has(cwd, slug, t)
        if has is None:
            return t, "send a release whose tag %s it could not find on origin (origin did not answer), so a re-send cannot be told from a cut" % t
        if not has:
            return t, "send %s, a release tag not on origin, which makes it a new cut" % t
    return None


def gh_repo(argv, env):
    slug = env.get("GH_REPO") or os.environ.get("GH_REPO")
    for j, a in enumerate(argv):
        if a in ("-R", "--repo") and j + 1 < len(argv):
            slug = argv[j + 1]
        elif a.startswith("--repo="):
            slug = a.split("=", 1)[1]
    return slug


def check_workflow_run(argv, env, cwd):
    i = argv.index("run", argv.index("workflow"))
    wf, fields, refs, j = None, [], [], i + 1
    while j < len(argv):
        a, nxt = argv[j], argv[j + 1] if j + 1 < len(argv) else ""
        if a in WF_FIELD:
            fields.append(nxt)
        elif a in ("-r", "--ref"):
            refs.append(nxt)
        elif a.startswith(("--ref=", "--field=", "--raw-field=")):
            (refs if a.startswith("--ref=") else fields).append(a.split("=", 1)[1])
        if a in WF_OPT_ARG:
            j += 2
            continue
        if wf is None and not a.startswith("-"):
            wf = a
        j += 1
    name = os.path.basename(wf or "")
    if name in CUT_WORKFLOWS:
        return deny("gh workflow run %s" % name, "cut a release")
    if any(f.split("=", 1)[0] == OVERRIDE_INPUT for f in fields):
        return deny("gh workflow run %s -f %s=..." % (name, OVERRIDE_INPUT), "ship past a red Tests run")
    if name not in RELEASE_WORKFLOWS:
        return None
    tags = [f.split("=", 1)[1] for f in fields if f.split("=", 1)[0] == "tag" and "=" in f]
    tags += [r for r in refs if release_tag(r)]
    if not tags:
        return deny("gh workflow run %s" % name, "start a release that names no existing tag")
    miss = missing_tags(cwd, gh_repo(argv, env), [t.removeprefix("refs/tags/") for t in tags])
    return deny("gh workflow run %s" % name, miss[1]) if miss else None


def check_release_create(argv, env, cwd):
    i = argv.index("create")
    tag = next((a for j, a in enumerate(argv[i + 1 :], i + 1)
                if not a.startswith("-") and argv[j - 1] not in ("-R", "--repo", "-t", "--title", "-n", "--notes",
                                                                  "-F", "--notes-file", "--target", "--discussion-category",
                                                                  "--notes-start-tag")), None)
    if not tag or not release_tag(tag):
        return None
    miss = missing_tags(cwd, gh_repo(argv, env), [tag])
    return deny("gh release create %s" % tag, "create a release tag") if miss else None


def check_api(head, argv):
    """A write to a GitHub API path under rulesets, environments or keys: `gh api` takes a path,
    curl an api.github.com URL."""
    path = next((a for a in argv[1:] if API_PATH.match(a) and GUARDED_API.search(a.split("?")[0])), None)
    if not path or FORGE.request_method(head if head == "curl" else "gh api", argv) in (None, "GET", "HEAD"):
        return None
    return deny("%s ... %s" % ("gh api" if head == "gh" else head, path), LOCKS)


def cut_script(argv, cwd):
    """The cut script argv runs, directly or through a shell (`bash scripts/release.sh`)."""
    cands = [argv[0]]
    if os.path.basename(argv[0]) in FORGE.SHELLS:
        cands += [a for a in argv[1:] if not a.startswith("-")][:1]
    for c in cands:
        parts = os.path.normpath(FORGE.resolve(cwd, c) or c).split(os.sep)
        if len(parts) >= 2 and (parts[-2], parts[-1]) in CUT_SCRIPTS:
            return c
    return None


def unwrap_timeout(argv):
    """`timeout [opts] <duration> cmd...` -> cmd..., the one wrapper forge-guard's unwrap lacks."""
    rest = argv[1:]
    while rest and rest[0].startswith("-"):
        rest = rest[2:] if rest[0] in ("-s", "--signal", "-k", "--kill-after") else rest[1:]
    return rest[1:]


def check(head, argv, env, cwd):
    if head == "timeout":
        argv = unwrap_timeout(argv)
        if not argv:
            return None
        head = os.path.basename(argv[0])
    if OVERRIDE_ENV in env:
        return deny("%s=..." % OVERRIDE_ENV, "ship past a red Tests run")
    if head in ("export", "declare", "typeset", "local") and any(a.startswith(OVERRIDE_ENV + "=") for a in argv[1:]):
        return deny("%s %s=..." % (head, OVERRIDE_ENV), "ship past a red Tests run")
    script = cut_script(argv, cwd)
    if script:
        return deny(script, "cut a release from this session")
    if head == "git":
        d, i = FORGE.git_verb(cwd, argv)
        if i < len(argv) and argv[i] == "tag":
            return check_tag(argv, i)
        if i < len(argv) and argv[i] == "push":
            return check_push(d, argv, i)
        return None
    if head == "curl":
        return check_api(head, argv)
    if head != "gh":
        return None
    words = FORGE.gh_words(argv)
    if words[:1] == ["api"]:
        return check_api(head, argv)
    if words[:2] == ["workflow", "run"]:
        return check_workflow_run(argv, env, cwd)
    if words[:2] == ["release", "create"]:
        return check_release_create(argv, env, cwd)
    if words[:2] == ["repo", "deploy-key"] and words[2:3] in (["add"], ["delete"]):
        return deny("gh repo deploy-key %s" % words[2], LOCKS)
    return None


def main():
    global FORGE
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not any(w in cmd for w in ("tag", "push", "workflow", "release", "publish", "ship.sh", "api",
                                  "rulesets", "environments", "keys", "deploy-key", OVERRIDE_ENV)):
        return
    FORGE = _forge()
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
