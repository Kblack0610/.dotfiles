#!/usr/bin/env python3
"""PreToolUse(Bash) guard: no agent session cuts a release.

The human, 2026-11-19 (epic ucp-2709, plan pure-dreaming-kernighan): a release must be impossible
for an agent to cut. The system cuts it (`cut.yml`, started by the `release-cut` lane when the
sprint's window says so). An agent fixes and improves the release pipeline, and may re-send a cut
that already exists. Until then a coordinator answered "no release until X" with an advisory hold
that nothing read, and the `release` skill told a session to tag and dispatch.

Denied: `git tag` creating a release tag (`v<n>.<n>...`, `<name>-v<n>.<n>...`); a `git push` that
carries one, deletes one, pushes a tag glob, or pushes `--tags`, `--follow-tags` or `--mirror`;
`gh release create` (or an API release write) of a release tag not yet on origin; an API write to
`git/refs` or `git/tags` naming a release tag; `gh workflow run cut.yml`, or a workflow named by id
or by a release-like display name; a run of a cut script (`scripts/release/ship.sh`,
`scripts/release.sh`, `scripts/publish.sh`); a `gh api` or curl write to `rulesets`,
`environments` or `keys`, and an environment's `gh secret`/`gh variable` write (the ruleset
bypass, the environments, the deploy key); and the untested override (`RELEASE_UNTESTED=`, a
workflow's `untested-reason` input). Wrappers (`timeout`, `nice`, `setsid`, `stdbuf`, `xargs`) are
walked through.
Allowed: a re-send, `gh workflow run <release workflow> -f tag=<t>` (or `--ref <t>`) when every
release tag it names is already on origin, `steam.yml -f run-id=<release run>` (an upload of a built tag), and
`gh run rerun`. A release workflow dispatch that
names no release tag is denied, since it could only cut.

The command walker is forge-guard's (cd, bash -c, eval, subshells). Codex runs this hook from
`.config/codex/hooks.json`. GitHub's ruleset is the backstop once cut.yml holds the only key
(P16). Fail-open on a parse error; a tag whose presence on origin cannot be read is denied, since
the guard cannot tell a re-send from a cut.
"""
import json
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE_TAG = re.compile(r"(?:^|-)v\d+\.\d+")
RELEASE_WORKFLOWS = {"release.yml", "phone-release.yml", "ios-release.yml", "steam.yml"}
CUT_WORKFLOWS = {"cut.yml"}
CUT_SCRIPTS = {("release", "ship.sh"), ("scripts", "release.sh"), ("scripts", "publish.sh")}
GUARDED_API = re.compile(r"/(rulesets|environments|keys)(?:/|$)")
TAG_API = re.compile(r"/(?:git/refs|git/tags|releases)(?:/|$)")
BODY_TAG = re.compile(r"(?:refs/tags/|tag_name\W+|\btag\W+)([\w.+-]+)")
RELEASE_WF_NAME = re.compile(r"cut|release|steam|ship|publish", re.I)
WRAP_OPT_ARG = {"timeout": {"-s", "--signal", "-k", "--kill-after"}, "nice": {"-n", "--adjustment"},
                "setsid": set(), "stdbuf": {"-i", "-o", "-e"},
                "xargs": {"-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "--max-args", "--max-procs",
                          "--delimiter", "--arg-file"}}
API_PATH = re.compile(r"^(?:https?://api\.github\.com)?/?(?:repos|orgs|user|enterprises)/")
LOCKS = "change a ruleset, an environment or a key, the locks that keep the cut in cut.yml"
OVERRIDE_ENV = "RELEASE_UNTESTED"
OVERRIDE_INPUT = "untested-reason"
TAG_LIST = {"-l", "--list", "-d", "--delete", "-v", "--verify", "--contains", "--no-contains",
            "--merged", "--no-merged", "--points-at"}
TAG_LIST_EQ = ("--list=", "--contains=", "--no-contains=", "--merged=", "--no-merged=", "--points-at=")
TAG_OPT_ARG = {"-m", "--message", "-F", "--file", "-u", "--local-user", "--cleanup", "--trailer"}
PUSH_ALL_TAGS = {"--tags", "--follow-tags", "--mirror"}
PUSH_OPT_ARG = {"-o", "--push-option", "--receive-pack", "--exec", "--repo"}
WF_FIELD = {"-f", "--raw-field", "-F", "--field"}
WF_OPT_ARG = {"-R", "--repo", "-r", "--ref", "--json"} | WF_FIELD

WHY = ("No agent cuts a release: cut.yml cuts it when the sprint's window says so (ucp-2709, the "
       "human 2026-11-19). An agent fixes an environment cause and re-sends a cut that exists: "
       "`gh run rerun <id> --failed` or `gh workflow run release.yml --ref <tag> -f tag=<tag>`; "
       "a workflow fix on main rides the next cut. The `release` skill says how.")
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
    """A `git tag` whose first name is a release tag, unless a list, delete or verify flag makes
    it a read. Option values are skipped first, so `-m -l` is a message, not a list."""
    args, opts, pos, j = argv[i + 1 :], [], [], 0
    while j < len(args):
        a = args[j]
        if a == "--":
            pos += args[j + 1 :]
            break
        if a in TAG_OPT_ARG or (a[:1] == "-" and a[:2] != "--" and a[-1:] in "mFu" and len(a) > 1):
            j += 2
            continue
        (opts if a.startswith("-") else pos).append(a)
        j += 1
    if any(a in TAG_LIST or a.startswith(TAG_LIST_EQ) for a in opts):
        return None
    if pos and release_tag(pos[0]):
        return deny("git tag %s" % pos[0], "create a release tag")
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
    for spec in pos[1:]:
        # a glob refspec (`refs/tags/*`, `v*`) pushes every tag it matches: only a branch glob passes
        if any("*" in side and not side.startswith("refs/heads/") for side in spec.lstrip("+").split(":")):
            return deny("git push %s" % spec, "push every tag the pattern matches, release tags included")
    for k, spec in enumerate(pos[1:], 1):
        if spec == "tag" and k + 1 < len(pos):
            spec = pos[k + 1]
        if any(pushes_tag(d, side) for side in spec.lstrip("+").split(":") if side):
            return deny("git push %s" % spec, "push or delete a release tag")
    return None


def origin_tags(cwd, slug, tags):
    """The subset of tags origin holds, or None when it cannot tell. One ls-remote for all of
    them, well under the hook's 10 s timeout. Origin is the clone of <owner>/<repo> project-map
    lists, else its GitHub URL, else cwd's."""
    if slug:
        clone = FORGE.clone_for(slug)
        where = (clone, "origin") if clone and os.path.isdir(clone) else (cwd, "https://github.com/%s.git" % slug)
    else:
        where = (cwd, "origin")
    try:
        r = subprocess.run(["git", "-C", where[0] or "/", "ls-remote", "--tags", where[1]]
                           + ["refs/tags/" + t for t in tags], capture_output=True, text=True, timeout=4)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return {line.split("refs/tags/", 1)[1].removesuffix("^{}") for line in r.stdout.splitlines() if "refs/tags/" in line}


def missing_tags(cwd, slug, tags):
    """The first tag of tags not on origin, with why; None when all are there."""
    has = origin_tags(cwd, slug, tags)
    if has is None:
        return tags[0], "send a release whose tag %s it could not find on origin (origin did not answer), so a re-send cannot be told from a cut" % tags[0]
    t = next((t for t in tags if t not in has), None)
    return (t, "send %s, a release tag not on origin, which makes it a new cut" % t) if t else None


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
    if wf and not name.endswith((".yml", ".yaml")) and (wf.isdigit() or RELEASE_WF_NAME.search(wf)):
        # an id or a display name ("Cut", "Release") hides which file runs: name the file
        return deny("gh workflow run %s" % wf, "start a workflow this guard cannot match to its file, so name the .yml")
    if any(f.split("=", 1)[0] == OVERRIDE_INPUT for f in fields):
        return deny("gh workflow run %s -f %s=..." % (name, OVERRIDE_INPUT), "ship past a red Tests run")
    if name not in RELEASE_WORKFLOWS:
        return None
    if name == "steam.yml" and any(f.split("=", 1)[0] == "run-id" and f.split("=", 1)[1:] not in ([], [""]) for f in fields):
        return None  # uploads a release.yml run, which steam.yml requires to have built a tag: a re-send
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


def api_body(argv, cwd):
    """The request's words plus its --input file, or None when the body cannot be read (stdin,
    a missing file)."""
    text = " ".join(argv[1:])
    for j, a in enumerate(argv):
        f = argv[j + 1] if a == "--input" and j + 1 < len(argv) else a.split("=", 1)[1] if a.startswith("--input=") else None
        if f is None:
            continue
        path = FORGE.resolve(cwd, f) if f != "-" else None
        try:
            with open(path) as fh:
                text += " " + fh.read(65536)
        except (OSError, TypeError):
            return None
    return text


def check_api(head, argv, cwd):
    """A GitHub API write that changes a lock (rulesets, environments, keys), makes, moves or
    deletes a release tag (git/refs, git/tags), or creates a release of a tag not on origin.
    `gh api` takes a path, curl an api.github.com URL."""
    path = next((a.split("?")[0] for a in argv[1:] if API_PATH.match(a)), None)
    if not path or FORGE.request_method(head if head == "curl" else "gh api", argv) in (None, "GET", "HEAD"):
        return None
    shown = "%s ... %s" % ("gh api" if head == "gh" else head, path)
    if GUARDED_API.search(path):
        return deny(shown, LOCKS)
    if not TAG_API.search(path):
        return None
    body = api_body(argv, cwd)
    if body is None:
        return deny(shown, "write a tag or a release from a body this guard cannot read")
    tags = [t for t in BODY_TAG.findall(body) if release_tag(t)]
    if not tags:
        return None
    if "/releases" not in path:
        return deny(shown, "make, move or delete a release tag")
    repo = re.search(r"repos/([^/]+/[^/]+)/", path)
    miss = missing_tags(cwd, repo and repo.group(1), tags)
    return deny(shown, miss[1]) if miss else None


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


def unwrap_wrapper(head, argv):
    """`timeout [opts] <duration> cmd...`, `nice`, `setsid`, `stdbuf`, `xargs` -> cmd..., the
    wrappers forge-guard's unwrap lacks."""
    rest = argv[1:]
    while rest and rest[0].startswith("-") and rest[0] != "--":
        rest = rest[2:] if rest[0] in WRAP_OPT_ARG[head] else rest[1:]
    rest = rest[1:] if rest[:1] == ["--"] else rest
    return rest[1:] if head == "timeout" else rest


def check(head, argv, env, cwd):
    if head in WRAP_OPT_ARG:
        # walk the wrapped command again, so `timeout 60 bash -c '...'` reaches its script
        inner = unwrap_wrapper(head, argv)
        return FORGE.reason(shlex.join(["%s=%s" % kv for kv in env.items()] + inner), cwd, check) if inner else None
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
        return check_api(head, argv, cwd)
    if head != "gh":
        return None
    words = FORGE.gh_words(argv)
    if words[:1] == ["api"]:
        return check_api(head, argv, cwd)
    if words[:1] in (["secret"], ["variable"]) and words[1:2] in (["set"], ["delete"], ["remove"]) \
            and any(a in ("-e", "--env") or a.startswith("--env=") for a in argv):
        return deny("gh %s %s --env" % tuple(words[:2]), LOCKS)
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
                                  "rulesets", "environments", "keys", "deploy-key", "secret", "variable", OVERRIDE_ENV)):
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
