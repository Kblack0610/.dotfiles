#!/usr/bin/env bats
# python-write-guard.py: a python write Edit or Write makes one-for-one is denied; a script that computes its write is not.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/python-write-guard.py"
  # Not scratch, and need not exist: the hook decides from the command alone.
  R=/srv/python-write-guard-fake
  # A ~ path must not resolve under TMPDIR, where the suite's throwaway HOME sits: the hook reads that as scratch.
  export HOME=/srv/python-write-guard-home
}

# decision <command> [permission mode]: allow, or the deny reason. The hook prints nothing to allow.
decision() {
  local out
  out=$(jq -nc --arg c "$1" --arg d "$R" --arg m "${2:-bypassPermissions}" \
    '{tool_name:"Bash", cwd:$d, permission_mode:$m, tool_input:{command:$c}}' | python3 "$HOOK")
  if [ -z "$out" ]; then echo allow; else jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out"; fi
}

denied() { assert_output --partial 'python-write-guard: '; }

@test "a str.replace patch of a named file is denied, naming Edit and the path, in every python form" {
  run decision "$(printf 'python3 - <<%sEOF%s\np = "%s/CLAUDE.md"\ns = open(p).read()\nassert "x" in s\nopen(p, "w").write(s.replace("x", "y"))\nEOF' "'" "'" "$R")"
  denied
  assert_output --partial "patches $R/CLAUDE.md"
  assert_output --partial 'Use Edit'
  for c in \
    $'cd /w && python3 <<EOF\nfrom pathlib import Path\np = Path("SKILL.md")\nt = p.read_text()\np.write_text(t.replace("a", "b", 1))\nEOF' \
    $'python3 - <<EOF\nwith open("/w/AGENTS.md") as f:\n    s = f.read()\nwith open("/w/AGENTS.md", "w") as f:\n    f.write(s.replace("x", "y"))\nEOF' \
    $'python3 - <<EOF\nimport os\nroot = os.path.expanduser("~/r")\np = f"{root}/memory/a.md"\ns = open(p).read()\ns = s.replace("x", "y")\ns = s.replace("z", "w")\nopen(p, "w").write(s)\nEOF' \
    $'python3 - <<EOF\nwith open("/w/memory/MEMORY.md", "r+") as f:\n    s = f.read(); f.seek(0); f.write(s.replace("a", "b")); f.truncate()\nEOF' \
    $'python3 - <<EOF\np = "/w/memory/MEMORY.md"\nopen(p, "w").write(open(p).read().replace("a", "b"))\nEOF\necho done # shlex cannot split this comment\'s quote' \
    $'python3 - 2>&1 <<EOF\np = "/w/memory/MEMORY.md"\nopen(p, "w").write(open(p).read().replace("a", "b"))\nEOF' \
    $'python3 -W ignore -X utf8 - <<EOF\np = "/w/memory/MEMORY.md"\nopen(p, "w").write(open(p).read().replace("a", "b"))\nEOF' \
    "bash -c \"python3 -c 's = open(\\\"/w/memory/MEMORY.md\\\").read(); open(\\\"/w/memory/MEMORY.md\\\",\\\"w\\\").write(s.replace(\\\"a\\\", \\\"b\\\"))'\""; do
    run decision "$c"
    denied
    assert_output --partial 'Use Edit'
  done
}

@test "a cd moves the path a relative write resolves against" {
  run decision $'cd /w && python3 <<EOF\nfrom pathlib import Path\np = Path("SKILL.md")\np.write_text(p.read_text().replace("a", "b"))\nEOF'
  assert_output --partial 'patches /w/SKILL.md'
}

@test "a heredoc run through a wrapper resolves against the cwd at its own line" {
  run decision $'cd /a && python3 x.py; cd /b; uv run python - <<EOF\nopen("CLAUDE.md", "w").write("x")\nEOF'
  assert_output --partial "literal string to /b/CLAUDE.md"
}

@test "a handle name reused for a read still counts its write" {
  run decision $'python3 - <<EOF\nwith open("/w/memory/MEMORY.md", "w") as f:\n    f.write("x")\nwith open("/w/memory/MEMORY.md") as f:\n    s = f.read()\nEOF'
  denied
}

@test "a literal string written to a named file is denied, naming Write" {
  run decision "python3 -c 'open(\".github/workflows/x.yml\", \"w\").write(\"hello\")'"
  denied
  assert_output --partial "literal string to $R/.github/workflows/x.yml"
  assert_output --partial 'Use Write'
  run decision $'python3 - <<EOF\nfrom pathlib import Path\nPath("/w/.agent/lessons/n.md").write_text("""# title\nbody\n""")\nEOF'
  assert_output --partial 'Use Write'
}

@test "negative control: computed content, loops, bytes, appends, scripts and scratch pass" {
  for c in \
    $'python3 - <<EOF\nimport re\np = "/w/a"\ns = open(p).read()\nopen(p, "w").write(re.sub("x", "y", s))\nEOF' \
    $'python3 - <<EOF\nimport json\nd = json.load(open("/w/a.json"))\nd["k"] = 1\njson.dump(d, open("/w/a.json", "w"), indent=2)\nEOF' \
    $'python3 - <<EOF\nfor p in ["/w/a", "/w/b"]:\n    s = open(p).read()\n    open(p, "w").write(s.replace("a", "b"))\nEOF' \
    $'python3 - <<EOF\np = "/w/a"\nlines = open(p).read().splitlines()\nopen(p, "w").write("\\n".join(l for l in lines if l))\nEOF' \
    $'python3 - <<EOF\nimport sys\nopen(sys.argv[1], "w").write("x")\nEOF' \
    $'python3 - <<EOF\nopen("/w/a.bin", "wb").write(b"x")\nEOF' \
    $'python3 - <<EOF\nopen("/w/log", "a").write("line\\n")\nEOF' \
    $'python3 script.py <<EOF\nopen("/w/x", "w").write("hi")\nEOF' \
    $'cat > /tmp/x.py <<EOF\nopen("/w/x", "w").write("hi")\nEOF\npython3 /tmp/x.py' \
    "python3 -c 'open(\"/tmp/x\", \"w\").write(\"hi\")'" \
    "cd /tmp && python3 -c 'open(\"out.txt\", \"w\").write(\"hi\")'" \
    "python3 -c 'open(\"$HOME/.cache/t/x\", \"w\").write(\"hi\")'" \
    "python3 -c 'print(open(\"/w/x\").read())'" \
    'echo "open(x) python"' \
    "python3 tool.py -c 'open(\"/w/a\", \"w\").write(\"x\")'" \
    "python3 2> /w/err - <<EOF"$'\nprint(1)\nEOF' \
    "python3 -c 'open(\"/proc/sys/vm/drop_caches\", \"w\").write(\"3\")'" \
    $'python3 - <<EOF\nthis is not python (\nEOF'; do
    run decision "$c"
    assert_output allow
  done
}

@test "negative control: a patch or literal of a file no Edit/Write guard checks passes outside manual mode" {
  for c in \
    $'python3 - <<EOF\np = "/w/a.py"\ns = open(p).read()\nopen(p, "w").write(s.replace("x", "y"))\nEOF' \
    $'cd /w && python3 <<EOF\nfrom pathlib import Path\np = Path("notes.md")\np.write_text(p.read_text().replace("a", "b"))\nEOF' \
    "python3 -c 'open(\"src/x.py\", \"w\").write(\"hello\")'" \
    $'python3 - <<EOF\nopen("/w/.github/README.yml.bak", "w").write("x")\nEOF'; do
    run decision "$c"
    assert_output allow
  done
  # The same patch of a guarded file is still denied: the narrowing is by target, not by form.
  run decision $'python3 - <<EOF\np = "/w/CLAUDE.md"\ns = open(p).read()\nopen(p, "w").write(s.replace("x", "y"))\nEOF'
  denied
}

@test "guarded: context-budget-guard's paths, workflow files and settings.json Edit denies; their look-alikes pass" {
  # context-budget-guard.sh's path test (its kind= branches): CLAUDE.md/AGENTS.md/SKILL.md by name, .md under memory/ or in .agent/lessons.
  for p in /w/CLAUDE.md /w/sub/AGENTS.md /w/s/SKILL.md /w/memory/MEMORY.md /w/p/memory/a.md /h/.agent/lessons/dotfiles.md \
    /w/.github/workflows/ci.yml /w/.github/workflows/a.yaml \
    /w/.env /w/app/.env.local /w/certs/k.pem "$HOME/.ssh/id_ed25519" "$HOME/.ssh/known_hosts" "$HOME/.config/gh/hosts.yml" /etc/shadow; do
    run decision "python3 -c 'open(\"$p\", \"w\").write(\"hello\")'"
    denied
  done
  run decision $'python3 - <<EOF\nimport os\np = os.path.expanduser("~/.config/gh/hosts.yml")\ns = open(p).read()\nopen(p, "w").write(s.replace("a", "b"))\nEOF'
  denied
  for p in /w/src/memory/cache.py /w/CLAUDE.md.bak /w/SKILL.md.orig /w/MEMORY.md /h/.agent/lessons/x.json /h/.agent/lessons/old/x.md \
    /w/.envrc /w/docs/env.md; do
    run decision "python3 -c 'open(\"$p\", \"w\").write(\"hello\")'"
    assert_output allow
  done
}

@test "with no settings.json beside the hooks, every path is guarded (the deny before the narrowing)" {
  mkdir -p "$BATS_TEST_TMPDIR/c/hooks"
  for f in python-write-guard.py forge-guard.py block-poll.py hosted-runner-guard.py; do
    cp "$BATS_TEST_DIRNAME/../../.claude/hooks/$f" "$BATS_TEST_TMPDIR/c/hooks/"
  done
  HOOK="$BATS_TEST_TMPDIR/c/hooks/python-write-guard.py"
  run decision "python3 -c 'open(\"/w/a.py\", \"w\").write(\"hello\")'"
  denied
}

@test "manual mode denies any python write outside scratch, and passes reads and scratch writes" {
  for c in \
    $'python3 - <<EOF\nimport json\njson.dump({}, open("/w/a.json", "w"))\nEOF' \
    $'python3 - <<EOF\nimport sys\nopen(sys.argv[1], "w").write("x")\nEOF' \
    $'python3 - <<EOF\nopen("/w/log", "a").write("line\\n")\nEOF'; do
    run decision "$c" default
    denied
    assert_output --partial 'manual mode is investigate-only'
  done
  run decision "python3 -c 'open(\"/tmp/x\", \"w\").write(\"hi\")'" default
  assert_output allow
  run decision "python3 -c 'print(open(\"/w/x\").read())'" default
  assert_output allow
  run decision $'python3 - <<EOF\nimport os, tempfile, subprocess\nd = tempfile.mkdtemp()\nopen(os.path.join(d, "x"), "w").write("y")\nsubprocess.run(["ls"], stdout=open(os.devnull, "w"))\nEOF' default
  assert_output allow
}

@test "settings.json runs the hook on Bash, fail-open" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$BATS_TEST_DIRNAME/../../.claude/settings.json"
  assert_output --partial 'python3 ~/.claude/hooks/python-write-guard.py || true'
  run bash -c "echo 'not json' | python3 '$HOOK'"
  assert_success
  assert_output ''
}
