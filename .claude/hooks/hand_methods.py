#!/usr/bin/env python3
"""Hand methods: the command forms a skill replaces, and the PreToolUse(Bash) guard that denies them.

A skill that stands in for a command sequence lists the hand-typed forms it replaces in its own
frontmatter, so the process and the forms it retires have one home:

    metadata:
      replaces:
        - match: '\\s-executeMethod\\s'        # Python regex over the command as code
          use: scripts/authoring/unity-method.sh <Namespace.Class.Method>
          mode: deny                           # deny | report
          where: unity-core-playground         # optional regex over the working directory
          unless: 'cd [^;&|]*asset-library'    # optional regex over the command as code
          why: a bare -batchmode skips the hold and the run slots

Readers: this guard (a `deny` row is refused, naming `use` and the skill), claude-recall's
`bypass` stats kind (every matching call, deny or report, counted per skill), and skill-drift's
BYPASSED and RETIRE findings built on that count. 2026-11-09: 700 playground sessions in 30 days
typed the gate-and-land block by hand while the skill that covers it ran in 110; a report alone
had not moved that (skill-refine's propose-only run, retired 2026-11-05), so a form with a script
is denied, not reported.

The command is matched as code the way block-poll.py parses it (it owns that parse): heredoc
bodies dropped, quoted text blanked (a quoted bare path stays a path), `sh -c`/`eval`/`ssh` payloads kept. A grep for the pattern
is not the pattern.

The rows are read from every deployed SKILL.md (CLAUDE_SKILLS, default ~/.claude/skills) and
cached in ~/.cache/claude-hooks/replaces-<root hash>.json, rebuilt when any SKILL.md or this file changes; this module is
the cache's one writer. `hand_methods.py --list` prints the rows; `--check <SKILL.md>` prints
what is wrong with one file's rows (skill-drift's BADMETA lint).
Fail-open: any error allows the call.
"""
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

HOOK = "hand-methods"
MODES = ("deny", "report")
_HERE = Path(__file__).resolve().parent


def skills_dir():
    return Path(os.environ.get("CLAUDE_SKILLS") or Path.home() / ".claude" / "skills")


def cache_path(root):
    """One cache per skills root, so skill-drift's or a test's root never evicts the hook's."""
    import hashlib
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    tag = hashlib.sha1(str(root).encode()).hexdigest()[:12]
    return Path(base) / "claude-hooks" / f"replaces-{tag}.json"


def _block_poll():
    spec = importlib.util.spec_from_file_location("block_poll", _HERE / "block-poll.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FRONTMATTER = re.compile(r"---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|$)", re.S)


def frontmatter(text):
    """The YAML between the opening `---` line and the next line that is exactly `---`, or None."""
    m = FRONTMATTER.match(text)
    return m.group(1) if m else None


def row_problems(row):
    """What is wrong with one replaces row, as short strings (skill-drift's lint reads these)."""
    if not isinstance(row, dict):
        return ["a replaces row is not a mapping"]
    out = []
    for key in ("match", "use"):
        if not isinstance(row.get(key), str) or not row[key].strip():
            out.append(f"replaces row needs a non-empty {key}")
    if row.get("mode", "deny") not in MODES:
        out.append(f"replaces mode must be one of {'|'.join(MODES)}")
    for key in ("match", "where", "unless"):
        if isinstance(row.get(key), str):
            try:
                re.compile(row[key])
            except re.error as e:
                out.append(f"replaces {key} is not a valid regex: {e}")
    unknown = set(row) - {"match", "use", "mode", "where", "unless", "why"}
    if unknown:
        out.append(f"replaces row has unknown keys: {', '.join(sorted(unknown))}")
    return out


def rows_of(skill_md):
    """The replaces rows one SKILL.md declares (raw dicts), [] when it declares none."""
    import yaml  # only on a cache miss: the import is the slow part of a call

    fm = frontmatter(Path(skill_md).read_text(errors="replace"))
    if fm is None:
        return []
    data = yaml.safe_load(fm)
    meta = data.get("metadata") if isinstance(data, dict) else None
    rows = meta.get("replaces") if isinstance(meta, dict) else None
    return rows if isinstance(rows, list) else []


def _fingerprint(root):
    files = sorted(root.glob("*/SKILL.md"))
    # This file too: a change to what a valid row is invalidates the cache.
    me = Path(__file__).stat()
    out = [["hand_methods.py", me.st_mtime_ns, me.st_size]]
    for f in files:
        try:
            st = f.stat()
        except OSError:
            continue
        out.append([f.parent.name, st.st_mtime_ns, st.st_size])
    return out


def load_rules(root=None):
    """Every valid replaces row of every deployed skill, as dicts with compiled regexes."""
    root = Path(root) if root else skills_dir()
    fp = _fingerprint(root)
    cache = cache_path(root)
    raw = None
    try:
        cached = json.loads(cache.read_text())
        if cached.get("root") == str(root) and cached.get("fingerprint") == fp:
            raw = cached["rows"]
    except (OSError, ValueError, KeyError, AttributeError):
        pass
    if raw is None:
        raw, failed = [], False
        for name, _, _ in fp[1:]:
            try:
                rows = rows_of(root / name / "SKILL.md")
            except Exception:
                # Unreadable now, or no yaml for this python3: use what parsed, cache nothing,
                # so the next call tries again rather than allowing everything until an edit.
                failed = True
                continue
            for i, row in enumerate(rows):
                if not row_problems(row):
                    raw.append({"skill": name, "id": f"{name}#{i + 1}", **row})
        try:
            if failed:
                raise OSError("partial rebuild, not cached")
            cache.parent.mkdir(parents=True, exist_ok=True)
            tmp = cache.with_suffix(".tmp.%d" % os.getpid())
            tmp.write_text(json.dumps({"root": str(root), "fingerprint": fp, "rows": raw}))
            os.replace(tmp, cache)
        except OSError:
            pass
    rules = []
    for r in raw:
        rules.append({**r, "mode": r.get("mode", "deny"),
                      "_match": re.compile(r["match"], re.S),
                      "_where": re.compile(r["where"]) if r.get("where") else None,
                      "_unless": re.compile(r["unless"], re.S) if r.get("unless") else None})
    return rules


_BP = None


def code_texts(cmd):
    """The command as code, block-poll's strict parse plus each $(...) body."""
    global _BP
    if _BP is None:
        _BP = _block_poll()
    cmd = _BP.strip_heredocs(cmd)
    # A quoted path ("/", '/mnt') is a path, not text: a row that names a root still sees it.
    cmd = re.sub(r"""(["'])((?:/|~)[^\s"'`\\()]*)\1""", r"\2", cmd)
    texts = _BP.code_texts(cmd, True)
    # Inside single quotes `...` and $(...) are literal (a commit message, a PR body), so only
    # substitutions outside them run.
    for sub in re.findall(r"\$\(([^()]*)\)|`([^`]*)`", re.sub(r"'[^']*'", "''", cmd)):
        texts += _BP.code_texts(sub[0] or sub[1], True)
    return texts


def matches(cmd, cwd, rules):
    """The rules one Bash command hits, in rule order."""
    if not rules or not cmd:
        return []
    texts = code_texts(cmd)
    hit = []
    for r in rules:
        if r["_where"] and not r["_where"].search(cwd or ""):
            continue
        if not any(r["_match"].search(t) for t in texts):
            continue
        if r["_unless"] and any(r["_unless"].search(t) for t in texts):
            continue
        hit.append(r)
    return hit


def reason(rule):
    why = f" Why: {rule['why']}" if rule.get("why") else ""
    return (f"{HOOK}: this is the hand-typed form of a process skill `{rule['skill']}` owns. "
            f"Use: {rule['use']}{why} (rule {rule['id']}; the rule lives in that skill's "
            f"metadata.replaces, fix it there if it is wrong).")


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name", "Bash") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    for r in matches(cmd, data.get("cwd") or os.getcwd(), load_rules()):
        if r["mode"] == "deny":
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse", "permissionDecision": "deny",
                "permissionDecisionReason": reason(r)}}))
            return


def list_rows():
    for r in load_rules():
        scope = f" where={r['where']}" if r.get("where") else ""
        print(f"{r['id']}\t{r['mode']}{scope}\t{r['match']}\t-> {r['use']}")


def check_file(skill_md):
    """`--check <SKILL.md>`: one line per problem in its metadata.replaces (skill-drift's lint)."""
    import yaml

    try:
        data = yaml.safe_load(frontmatter(Path(skill_md).read_text(errors="replace")) or "")
    except Exception as e:
        return ["frontmatter does not parse: " + " ".join(str(e).split())[:80]]
    meta = data.get("metadata") if isinstance(data, dict) else None
    if not isinstance(meta, dict) or "replaces" not in meta:
        return []
    rows = meta["replaces"]
    if not isinstance(rows, list) or not rows:
        return ["metadata.replaces must be a non-empty list of rows"]
    return [f"row {i}: {p}" for i, row in enumerate(rows, 1) for p in row_problems(row)]


if __name__ == "__main__":
    if sys.argv[1:] == ["--list"]:
        list_rows()
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        for line in check_file(sys.argv[2]):
            print(line)
        sys.exit(0)
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
