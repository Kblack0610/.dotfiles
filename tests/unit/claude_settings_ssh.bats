#!/usr/bin/env bats
# .claude/settings.json ssh denies: Read and Edit refuse every ssh key shape (any name form, any
# subfolder, backups) but leave the ssh config editable. The globs are applied gitignore-style,
# as Claude Code reads them: `*` stays inside one path segment, `**/` spans zero or more.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SETTINGS="$BATS_TEST_DIRNAME/../../.claude/settings.json"
}

# denied TOOL PATH -> exit 0 when a `TOOL(//...)` deny rule matches the absolute PATH.
denied() {
  python3 - "$SETTINGS" "$1" "$2" <<'PY'
import json, re, sys
settings, tool, path = sys.argv[1:]
def rx(glob):
    out, i = "", 0
    while i < len(glob):
        if glob.startswith("**/", i): out, i = out + "(?:.*/)?", i + 3
        elif glob.startswith("**", i): out, i = out + ".*", i + 2
        elif glob[i] == "*": out, i = out + "[^/]*", i + 1
        else: out, i = out + re.escape(glob[i]), i + 1
    return re.compile(out + r"\Z")
for rule in json.load(open(settings))["permissions"]["deny"]:
    m = re.fullmatch(r"%s\(//(.*)\)" % tool, rule)
    if m and rx("/" + m.group(1)).match(path):
        sys.exit(0)
sys.exit(1)
PY
}

@test "every ssh key shape is denied to Read and Edit, in any subfolder" {
  local t p
  for t in Read Edit; do
    for p in /home/u/.ssh/id_rsa /home/u/.ssh/id_ed25519_sk /home/u/.ssh/github_ed25519 \
             /home/u/.ssh/work_rsa /home/u/.ssh/keys/deploy_ecdsa /home/u/.ssh/old/legacy_dsa \
             /home/u/.ssh/authorized_keys /home/u/.ssh/ssh_host_ed25519_key \
             /home/u/.ssh/known_hosts /home/u/.ssh/putty.ppk /home/u/.ssh/login.bak \
             /home/u/.dotfiles-private/.ssh/id_rsa; do
      run denied "$t" "$p"
      assert_success "$t $p is not denied"
    done
  done
}

@test "negative control: the ssh config stays readable and editable" {
  local t p
  for t in Read Edit; do
    for p in /home/u/.ssh/config /home/u/.dotfiles-private/.ssh/config /home/u/.ssh/config.d/hosts; do
      run denied "$t" "$p"
      assert_failure "$t $p is denied"
    done
  done
}
