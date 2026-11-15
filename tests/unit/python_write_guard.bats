#!/usr/bin/env bats
# python-write-guard.py: a python write Edit or Write makes one-for-one is denied; a script that computes its write is not.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../../.claude/hooks/python-write-guard.py"
  # Not scratch, and need not exist: the hook decides from the command alone.
  R=/srv/python-write-guard-fake
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
  run decision "$(printf 'python3 - <<%sEOF%s\np = "%s/a.py"\ns = open(p).read()\nassert "x" in s\nopen(p, "w").write(s.replace("x", "y"))\nEOF' "'" "'" "$R")"
  denied
  assert_output --partial "patches $R/a.py"
  assert_output --partial 'Use Edit'
  for c in \
    $'cd /w && python3 <<EOF\nfrom pathlib import Path\np = Path("f.txt")\nt = p.read_text()\np.write_text(t.replace("a", "b", 1))\nEOF' \
    $'python3 - <<EOF\nwith open("/w/a.md") as f:\n    s = f.read()\nwith open("/w/a.md", "w") as f:\n    f.write(s.replace("x", "y"))\nEOF' \
    $'python3 - <<EOF\nimport os\nroot = os.path.expanduser("~/r")\np = f"{root}/a.md"\ns = open(p).read()\ns = s.replace("x", "y")\ns = s.replace("z", "w")\nopen(p, "w").write(s)\nEOF' \
    $'python3 - <<EOF\nwith open("/w/a", "r+") as f:\n    s = f.read(); f.seek(0); f.write(s.replace("a", "b")); f.truncate()\nEOF' \
    $'python3 - <<EOF\np = "/w/a"\nopen(p, "w").write(open(p).read().replace("a", "b"))\nEOF\necho done # shlex cannot split this comment\'s quote' \
    "bash -c \"python3 -c 's = open(\\\"/w/a\\\").read(); open(\\\"/w/a\\\", \\\"w\\\").write(s.replace(\\\"a\\\", \\\"b\\\"))'\""; do
    run decision "$c"
    denied
    assert_output --partial 'Use Edit'
  done
}

@test "a cd moves the path a relative write resolves against" {
  run decision $'cd /w && python3 <<EOF\nfrom pathlib import Path\np = Path("f.txt")\np.write_text(p.read_text().replace("a", "b"))\nEOF'
  assert_output --partial 'patches /w/f.txt'
}

@test "a literal string written to a named file is denied, naming Write" {
  run decision "python3 -c 'open(\"src/x.py\", \"w\").write(\"hello\")'"
  denied
  assert_output --partial "literal string to $R/src/x.py"
  assert_output --partial 'Use Write'
  run decision $'python3 - <<EOF\nfrom pathlib import Path\nPath("/w/n.md").write_text("""# title\nbody\n""")\nEOF'
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
    $'python3 - <<EOF\nthis is not python (\nEOF'; do
    run decision "$c"
    assert_output allow
  done
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
}

@test "settings.json runs the hook on Bash, fail-open" {
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$BATS_TEST_DIRNAME/../../.claude/settings.json"
  assert_output --partial 'python3 ~/.claude/hooks/python-write-guard.py || true'
  run bash -c "echo 'not json' | python3 '$HOOK'"
  assert_success
  assert_output ''
}
