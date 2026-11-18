#!/usr/bin/env bats
# gh-hosted-runner-audit: MOVE for a private repo's hosted job, UNSAFE for a public repo's self-hosted one.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  AUDIT="$BATS_TEST_DIRNAME/../../.local/bin/gh-hosted-runner-audit"
  FIX="$BATS_TEST_TMPDIR/fix"
  export AUDIT_FIX="$FIX" PROJECT_MAP_FILE="$BATS_TEST_TMPDIR/project-map.json"
  jq -n '{github_runners: {self_hosted_only: ["acme"], allow: {"acme/priv:.github/workflows/rel.yml": "release on a hosted Mac"}}}' >"$PROJECT_MAP_FILE"
  recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n '[{nameWithOwner: "acme/priv", visibility: "PRIVATE"}, {nameWithOwner: "acme/pub", visibility: "PUBLIC"},
          {nameWithOwner: "acme/dorm", visibility: "PRIVATE"}, {nameWithOwner: "acme/bare", visibility: "PRIVATE"}]' >"$BATS_TEST_TMPDIR/acme.repos"
  wf() { mkdir -p "$FIX/$1/wf"; cat >"$FIX/$1/wf/$2"; }
  wf acme/priv ci.yml <<'EOF'
jobs:
  hosted:
    runs-on: ubuntu-latest
  fallback:
    runs-on: ${{ fromJSON(vars.LINUX_RUNNER_LIGHT || '"ubuntu-latest"') }}
  home:
    runs-on: [self-hosted, linux] # was ubuntu-latest
  matrix:
    runs-on: ${{ matrix.os }}
  call:
    uses: acme/shared/.github/workflows/lint.yml@main
EOF
  wf acme/priv rel.yml <<<$'jobs:\n  mac:\n    runs-on: macos-14'
  wf acme/priv off.yml <<<$'jobs:\n  old:\n    runs-on: ubuntu-latest'
  wf acme/priv broken.yml <<<$'jobs:\n  x: [unclosed'
  echo off.yml >"$FIX/acme/priv/disabled"
  echo "$recent" >"$FIX/acme/priv/last"
  wf acme/pub apk.yml <<<$'jobs:\n  build:\n    runs-on:\n      - self-hosted\n      - macOS'
  wf acme/pub ci.yml <<<$'jobs:\n  t:\n    runs-on: ubuntu-latest'
  wf acme/dorm ci.yml <<<$'jobs:\n  t:\n    runs-on: ubuntu-22.04'
  echo 2025-01-01T00:00:00Z >"$FIX/acme/dorm/last"
  # gh stub: answers the audit's calls from $AUDIT_FIX; a repo with no wf dir has no workflows (404).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<EOF
#!/usr/bin/env python3
import base64, json, os, sys
fix, a = os.environ["AUDIT_FIX"], sys.argv[1:]
if a[:2] == ["repo", "list"]:
    sys.exit(print(open("$BATS_TEST_TMPDIR/" + a[2] + ".repos").read()))
_, o, r, rest = [x for x in a if not x.startswith("-") and x != "api"][0].split("/", 3)
rest = rest.removeprefix("contents/")
d = f"{fix}/{o}/{r}"
names = sorted(os.listdir(d + "/wf")) if os.path.isdir(d + "/wf") else None
off = open(d + "/disabled").read().split() if os.path.exists(d + "/disabled") else []
if rest == ".github/workflows":
    if names is None:
        sys.exit(print("gh: Not Found (HTTP 404)", file=sys.stderr) or 1)
    print(json.dumps([{"type": "file", "name": n, "path": ".github/workflows/" + n} for n in names]))
elif rest.startswith("actions/workflows"):
    print(json.dumps([{"workflows": [{"path": ".github/workflows/" + n, "state": "disabled_manually" if n in off else "active"} for n in names or []]}]))
elif rest.startswith("actions/runs"):
    last = open(d + "/last").read().strip() if os.path.exists(d + "/last") else None
    print(json.dumps({"workflow_runs": [{"created_at": last}] if last else []}))
else:
    print(json.dumps({"content": base64.b64encode(open(d + "/wf/" + rest.rsplit("/", 1)[1], "rb").read()).decode()}))
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "a private repo's hosted label and hosted fallback are MOVE, and the run fails" {
  run "$AUDIT"
  assert_failure
  assert_line --partial $'MOVE\tacme/priv (private)\t.github/workflows/ci.yml\thosted\tubuntu-latest'
  assert_line --partial $'MOVE\tacme/priv (private)\t.github/workflows/ci.yml\tfallback'
  assert_line --partial '3 job(s) to fix'
}

@test "a public repo's self-hosted job is UNSAFE; its hosted job is fine" {
  run "$AUDIT"
  assert_line --partial $'UNSAFE\tacme/pub (public)\t.github/workflows/apk.yml\tbuild\t- self-hosted - macOS'
  refute_line --partial 'acme/pub (public)	.github/workflows/ci.yml'
}

@test "a dormant repo is IDLE, an expression is EXPR, broken YAML is PARSE" {
  run "$AUDIT"
  assert_line --partial $'IDLE\tacme/dorm (private)'
  assert_line --partial $'EXPR\tacme/priv (private)\t.github/workflows/ci.yml\tmatrix'
  assert_line --partial $'PARSE\tacme/priv\t.github/workflows/broken.yml'
}

@test "self-hosted with a comment naming ubuntu-latest, an allowlisted workflow and a disabled one are not findings" {
  run "$AUDIT"
  refute_line --partial $'\thome\t'
  refute_line --partial 'rel.yml'
  refute_line --partial 'off.yml'
  run "$AUDIT" --all
  assert_line --partial $'ok\tacme/priv (private)\t.github/workflows/ci.yml\thome\t[self-hosted, linux]'
  assert_line --partial $'ok\tacme/priv (private)\t.github/workflows/rel.yml\tmac\tmacos-14'
}

@test "with nothing to fix it exits 0" {
  rm -r "$FIX/acme/priv/wf" "$FIX/acme/pub/wf"
  run "$AUDIT"
  assert_success
  assert_line --partial '0 job(s) to fix'
}

@test "a gh failure other than a 404 stops the audit instead of reading clean" {
  printf '#!/bin/sh\necho "HTTP 401: Bad credentials" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/gh"
  run "$AUDIT"
  assert_failure
  assert_output --partial 'Bad credentials'
  refute_output --partial 'job(s) to fix'
}
