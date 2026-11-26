#!/usr/bin/env bats
# kit-lock and the kit's fetch-kit.py: bump pins a site's lock and Dockerfile to a kit commit,
# status flags a site pinned before a README (contract) change, and the fetch refuses a file
# whose hash is not the lock's. The kit is a fixture git repo with the real fetch-kit.py; the
# fetch reads a file:// tree of one commit, so nothing touches the network.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/kit-lock"
  FETCH="$REPO_ROOT/.local/src/web-kit/fetch-kit.py"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export KIT_REPO="$SANDBOX/kit" KIT_REF=main KIT_SITES="$SANDBOX/sites"
  KIT="$KIT_REPO/.local/src/web-kit"
  mkdir -p "$KIT"
  git init -q -b main "$KIT_REPO"
  cp "$FETCH" "$KIT/fetch-kit.py"
  echo 'contract v1' > "$KIT/README.md"
  echo 'a { color: red }' > "$KIT/a.css"
  printf 'font\0bytes' > "$KIT/f.woff2"
  kit_commit one
  PIN1=$(git -C "$KIT_REPO" rev-parse HEAD)

  SITE="$SANDBOX/site"
  mkdir -p "$SITE/web"
  git init -q -b main "$SITE"
  zero=$(printf '0%.0s' {1..64})
  jq -n --arg z "$zero" --arg c "$(printf '0%.0s' {1..40})" '{repo: "o/kit", commit: $c, path: ".local/src/web-kit", files: {"a.css": $z, "f.woff2": $z}}' > "$SITE/web/kit.lock"
  printf 'FROM scratch\nADD --checksum=sha256:%s https://raw.githubusercontent.com/o/kit/%s/.local/src/web-kit/fetch-kit.py /fetch-kit.py\n' \
    "$zero" "$(printf '0%.0s' {1..40})" > "$SITE/Dockerfile"
}

kit_commit() { git -C "$KIT_REPO" add -A && git -C "$KIT_REPO" commit -q -m "$1"; }
kit_file_sha() { git -C "$KIT_REPO" show "$1:.local/src/web-kit/$2" | sha256sum | cut -d' ' -f1; }

# serve <commit> -> a file:// tree of that kit commit; echoes the --url template for fetch-kit.py.
serve() {
  mkdir -p "$SANDBOX/srv/$1"
  git -C "$KIT_REPO" archive "$1" | tar -x -C "$SANDBOX/srv/$1"
  echo "file://${SANDBOX// /%20}/srv/{commit}/{path}/{name}"
}

@test "bump pins the lock and the Dockerfile's fetch-kit.py checksum to the commit, and a second bump changes nothing" {
  run "$SUBJECT" bump "$SITE/web/kit.lock" "$PIN1"
  assert_success
  assert_output --partial '2 files, 2 changed'
  assert_equal "$(jq -r .commit "$SITE/web/kit.lock")" "$PIN1"
  assert_equal "$(jq -r '.files["a.css"]' "$SITE/web/kit.lock")" "$(kit_file_sha "$PIN1" a.css)"
  assert_equal "$(jq -r '.files["f.woff2"]' "$SITE/web/kit.lock")" "$(kit_file_sha "$PIN1" f.woff2)"
  run grep -c "ADD --checksum=sha256:$(kit_file_sha "$PIN1" fetch-kit.py) https://raw.githubusercontent.com/o/kit/$PIN1/.local/src/web-kit/fetch-kit.py /fetch-kit.py" "$SITE/Dockerfile"
  assert_output 1

  cp "$SITE/web/kit.lock" "$SANDBOX/lock.1" && cp "$SITE/Dockerfile" "$SANDBOX/df.1"
  run "$SUBJECT" bump "$SITE/web/kit.lock" "$PIN1"
  assert_success
  assert_output --partial '0 changed'
  cmp "$SANDBOX/lock.1" "$SITE/web/kit.lock"
  cmp "$SANDBOX/df.1" "$SITE/Dockerfile"
}

@test "bump refuses a file the kit does not have at the commit, and leaves the lock as it was" {
  jq '.files["gone.css"] = ""' "$SITE/web/kit.lock" > "$SANDBOX/l" && mv "$SANDBOX/l" "$SITE/web/kit.lock"
  cp "$SITE/web/kit.lock" "$SANDBOX/before"
  run "$SUBJECT" bump "$SITE/web/kit.lock" "$PIN1"
  assert_failure 2
  assert_output --partial 'gone.css is not in the kit'
  cmp "$SANDBOX/before" "$SITE/web/kit.lock"
}

@test "bump with --dockerfile that has no fetch-kit.py ADD line refuses before it moves the lock" {
  printf 'FROM scratch\n' > "$SANDBOX/Other.Dockerfile"
  cp "$SITE/web/kit.lock" "$SANDBOX/before"
  run "$SUBJECT" bump "$SITE/web/kit.lock" "$PIN1" --dockerfile "$SANDBOX/Other.Dockerfile"
  assert_failure 2
  assert_output --partial 'has no '
  cmp "$SANDBOX/before" "$SITE/web/kit.lock"
}

@test "status flags the site pinned before a README change and exits 1; a site at the tip reads same" {
  "$SUBJECT" bump "$SITE/web/kit.lock" "$PIN1" >/dev/null
  echo 'b { }' >> "$KIT/a.css" && kit_commit two
  printf '%s web/kit.lock\n' "$SITE" > "$KIT_SITES"
  run "$SUBJECT" status
  assert_success
  assert_line --regexp "^site +${PIN1:0:9} +1 +same$"

  echo 'contract v2' > "$KIT/README.md" && kit_commit three
  run "$SUBJECT" status
  assert_failure 1
  assert_line --regexp "^site +${PIN1:0:9} +2 +README changed$"

  "$SUBJECT" bump "$SITE/web/kit.lock" >/dev/null
  run "$SUBJECT" status
  assert_success
  assert_line --regexp "^site +[0-9a-f]{9} +0 +same$"
}

@test "status with no sites file says where it looked" {
  run "$SUBJECT" status
  assert_failure 2
  assert_output --partial "no sites file at $KIT_SITES"
}

@test "fetch-kit.py fetches a bumped lock, and refuses a tampered file without writing any (negative control)" {
  "$SUBJECT" bump "$SITE/web/kit.lock" "$PIN1" >/dev/null
  url=$(serve "$PIN1")
  run python3 -I "$FETCH" "$SITE/web/kit.lock" "$SANDBOX/out" --url "$url"
  assert_success
  cmp "$KIT/a.css" "$SANDBOX/out/a.css"
  cmp "$KIT/f.woff2" "$SANDBOX/out/f.woff2"

  printf x >> "$SANDBOX/srv/$PIN1/.local/src/web-kit/f.woff2"
  run python3 -I "$FETCH" "$SITE/web/kit.lock" "$SANDBOX/out2" --url "$url"
  assert_failure 1
  assert_output --partial 'kit file f.woff2 does not match the lock'
  [ ! -e "$SANDBOX/out2" ]
}

@test "fetch-kit.py retries a 503, a 429 and a reset mid-body, and fails a 404 at once" {
  run python3 -I - "$FETCH" <<'PY'
import hashlib, importlib.util, sys, urllib.error
spec = importlib.util.spec_from_file_location("fetch_kit", sys.argv[1])
fk = importlib.util.module_from_spec(spec); spec.loader.exec_module(fk)
body = b"body"
lock = {"repo": "r", "commit": "c", "path": "p", "files": {"a.css": hashlib.sha256(body).hexdigest()}}
import tempfile, pathlib
dest = pathlib.Path(tempfile.mkdtemp())
fails = [urllib.error.HTTPError("u", 503, "max_conn", {}, None), urllib.error.HTTPError("u", 429, "slow", {}, None), ConnectionResetError()]
calls, waits = [], []
def flaky(u):
    calls.append(u)
    if fails:
        raise fails.pop(0)
    return body
fk.fetch(lock, dest, get=flaky, sleep=waits.append)
assert (len(calls), len(waits)) == (4, 3), (calls, waits)
assert (dest / "a.css").read_bytes() == body
waits.clear()
def gone(u):
    raise urllib.error.HTTPError(u, 404, "nope", {}, None)
try:
    fk.fetch(lock, dest, get=gone, sleep=waits.append)
except urllib.error.HTTPError:
    assert waits == [], waits
    print("ok")
PY
  assert_success
  assert_output ok
}
