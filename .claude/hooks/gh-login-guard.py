#!/usr/bin/env python3
"""PreToolUse(Bash) guard: a session never changes this host's gh login; signing gh back in is the human's.

2026-11-17: a bats run deleted ~/.config/gh/hosts.yml and signed the fleet out (suite_home.bash now
keeps tests off the real home); the human asked (2026-11-18, ar-2876) that no session can do that
again and that every session knows a lost login is theirs to redo, so none spends turns on a
workaround.

Denied: `gh auth login|logout|refresh|switch`, unless the config dir gh would use for that command
(GH_CONFIG_DIR, else $XDG_CONFIG_HOME/gh, else $HOME/.config/gh, each from the command's own
assignments over the session's env) resolves to somewhere else, as a test on a throwaway home does;
and any command that removes or writes the gh config dir: rm, rmdir, unlink, shred, truncate, tee,
`dd of=`, mv (either side), the destination of cp, ln, install or rsync, `sed -i`, find with -delete
or -exec, or a `>`/`>>` redirect, whose path is in that dir (rm, rmdir, an mv source, a find start that no -name test keeps off the gh files,
and an `rsync --delete` destination also on any dir above it). The dir is $GH_CONFIG_DIR,
$XDG_CONFIG_HOME/gh and ~/.config/gh, as this hook sees them. Commands are walked with forge-guard's
walker (cd, subshells, bash -c, eval); globs are expanded. Not covered: a path built by $(...) or a
variable the hook cannot see, a script that does it, a redirect after a cd, a copy into a dir above
the gh dir. Fail-open: any error allows the command. `gh auth status`, `gh auth token` and reading
the dir pass.
"""
import fnmatch
import glob
import os
import re
import shlex

import hooklib

AUTH_WRITES = {"login", "logout", "refresh", "switch"}
REMOVERS = {"rm", "rmdir", "unlink", "shred", "truncate", "tee"}
ABOVE_TOO = {"rm", "rmdir"}  # removing a dir above the gh dir removes it too
COPIERS = {"cp", "ln", "install", "rsync"}
SED_IN_PLACE = re.compile(r"-[a-zA-Z]*i\S*|--in-place(=.*)?")
FIND_REMOVES = {"-delete", "-exec", "-execdir", "-ok", "-okdir"}
GH_FILES = ("gh", "hosts.yml", "config.yml", "state.yml")
PREFILTER = r"\bgh\b|GH_CONFIG_DIR|XDG_CONFIG_HOME|\.config|(?<![\w.-])(rm|rmdir|mv|find)(?![\w.-])"

MSG = (
    "gh-login-guard: {what} would change this host's gh login ({dir}). That login is the human's: "
    "no session logs gh in or out, refreshes, switches or rewrites it, and when it is gone only the "
    "human signs it back in (`gh auth login`). Do not rebuild it another way: no `gh auth login "
    "--with-token` from rbw or SOPS, no hosts.yml copied from another host, no PAT. If gh is signed "
    "out, say so in one line, post the one shared ask (`agent-ask post --blocker <host>/gh:auth ...`), "
    "and carry on with the work that does not need gh. A test on a throwaway home sets GH_CONFIG_DIR "
    "or HOME on the gh command itself."
)



FORGE = None  # loaded past decide's prefilter, or set by walker-guards.py: it runs on every Bash call


def gh_dir_for(env):
    """The config dir gh reads its login from under env, by gh's own precedence."""
    if env.get("GH_CONFIG_DIR"):
        return env["GH_CONFIG_DIR"]
    if env.get("XDG_CONFIG_HOME"):
        return os.path.join(env["XDG_CONFIG_HOME"], "gh")
    return os.path.join(env.get("HOME") or "~", ".config", "gh")


def gh_dir_list():
    """Where gh reads this host's login first, then the other dirs it may sit in."""
    xdg = os.environ.get("XDG_CONFIG_HOME")
    ds = [os.environ.get("GH_CONFIG_DIR"), os.path.join(xdg, "gh") if xdg else None, os.path.expanduser("~/.config/gh")]
    return [d for d in ds if d]


def gh_dirs():
    """Each gh config dir, as written and resolved."""
    return {x for d in gh_dir_list() for x in (os.path.normpath(d), os.path.realpath(d))}


def paths(word, cwd):
    """The paths a word names, globs expanded; none when the hook cannot see it ($(...), unset $var)."""
    p = FORGE.resolve(cwd, word)
    if p is None:
        return []
    found = sorted(glob.glob(p)) if glob.has_magic(p) else []
    return [os.path.normpath(x) for x in (found or [p])]


def hit(word, cwd, above):
    """The gh dir word reaches: it is the dir or inside it, or (above) a dir holding it."""
    for p in paths(word, cwd):
        for c in {p, os.path.realpath(p)}:
            for d in gh_dirs():
                if c == d or c.startswith(d + "/") or (above and d.startswith(c.rstrip("/") + "/")):
                    return d
    return None


def operands(argv):
    """argv's non-option words, `--` ending the options."""
    out, opts = [], True
    for a in argv[1:]:
        if opts and a == "--":
            opts = False
        elif opts and a.startswith("-") and a != "-":
            continue
        else:
            out.append(a)
    return out


def targets(head, argv):
    """(word, above) for each path argv writes or removes."""
    ops = operands(argv)
    if head in REMOVERS:
        return [(t, head in ABOVE_TOO) for t in ops]
    if head == "dd":
        return [(a[3:], False) for a in argv[1:] if a.startswith("of=")]
    if head == "mv":  # a source moved away, or a dir above the gh dir moved with it; the destination
        return [(t, True) for t in ops[:-1]] + [(t, False) for t in ops[-1:]]
    if head in COPIERS:
        t = next((a.split("=", 1)[1] for a in argv if a.startswith("--target-directory=")), None)
        t = t or next((argv[i + 1] for i, a in enumerate(argv[:-1]) if a in ("-t", "--target-directory")), None)
        t = t or (ops[-1] if len(ops) > 1 else None)
        return [(t, head == "rsync" and any(a.startswith("--del") for a in argv))] if t else []
    if head == "sed" and any(SED_IN_PLACE.fullmatch(a) for a in argv[1:]):
        return [(t, False) for t in ops]
    if head == "find" and FIND_REMOVES & set(argv):
        starts = []
        for a in argv[1:]:
            if a.startswith(("-", "(", "!")):
                break
            starts.append(a)
        # A start above the gh dir counts unless a -name test keeps every gh file out (a cleanup
        # of ~ by name passes).
        names = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a in ("-name", "-iname")]
        above = not names or any(fnmatch.fnmatch(f, n) for n in names for f in GH_FILES)
        return [(t, above) for t in starts]
    return []


def check(head, argv, env, cwd):
    if head == "gh":
        words = FORGE.gh_words(argv)
        if len(words) < 2 or words[0] != "auth" or words[1] not in AUTH_WRITES:
            return None
        d = gh_dir_for({**os.environ, **env})
        if FORGE.resolve(cwd, d) is not None and not hit(d, cwd, True):
            return None  # a throwaway gh home
        return MSG.format(what="`gh auth %s`" % words[1], dir=gh_dir_list()[0])
    for t, above in targets(head, argv):
        d = hit(t, cwd, above)
        if d:
            return MSG.format(what="`%s %s`" % (head, t), dir=d)
    return None


def redirects(cmd, cwd):
    """MSG for a `>`, `>>` or `&>` redirect into the gh dir, read with the shell's quoting and
    resolved against the starting cwd. `>&2` and `2>&1` duplicate a descriptor and pass."""
    lex = shlex.shlex(cmd.replace("\\\n", " "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    toks = list(lex)
    for op, word in zip(toks, toks[1:]):
        if set(op) <= set("<>&|;()") and ">" in op and not op.endswith("&"):
            d = hit(word, cwd, False)
            if d:
                return MSG.format(what="a redirect into %s" % word, dir=d)
    return None


def decide(data):
    # gate: hook-gh-login-guard
    """The deny reason for one PreToolUse payload, or None. walker-guards.py calls this."""
    global FORGE
    if data.get("tool_name", "Bash") != "Bash":
        return None
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not (re.search(PREFILTER, cmd) or any(d in cmd for d in gh_dir_list())):
        return None
    FORGE = FORGE or hooklib.load("forge-guard")
    cwd = data.get("cwd") or os.getcwd()
    r = FORGE.reason(cmd, cwd, check)
    try:
        r = r or redirects(FORGE._strip_heredocs()(cmd), cwd)
    except ValueError:  # an unbalanced quote: no shell would run it either
        pass
    return r


if __name__ == "__main__":
    hooklib.run(decide)
