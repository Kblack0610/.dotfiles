#!/usr/bin/env bats
# .local/bin/gh (the wrapper) and .local/bin/gh-app: which calls leave on the App's token, which
# stay on the human's, and what the call log records. A read routed wrong fails an agent's
# command; a write routed to the App would post as the bot. The real gh, curl and the API are stubs.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  WRAP="$BATS_TEST_DIRNAME/../../.local/bin/gh"
  GHAPP="$BATS_TEST_DIRNAME/../../.local/bin/gh-app"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  # The real gh: records the token it was given and its args, reads stdin when told to, exits $REAL_RC.
  cat > "$STUB/real-gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-none}" "$*" >> "$BATS_TEST_TMPDIR/real.log"
case "$*" in *--body-file\ -*) cat >> "$BATS_TEST_TMPDIR/stdin.log" ;; esac
exit "${REAL_RC:-0}"
SH
  # gh-app: acme has an installation, broken fails to mint, anyone else has none.
  cat > "$STUB/gh-app" <<'SH'
#!/usr/bin/env bash
case "$2" in acme) echo tok-acme ;; broken) echo 'gh-app: minting failed' >&2; exit 1 ;; *) exit 2 ;; esac
SH
  chmod +x "$STUB/real-gh" "$STUB/gh-app"
  export PATH="$STUB:$PATH" GH_REAL="$STUB/real-gh" GH_CALLS_DIR="$BATS_TEST_TMPDIR/calls" BATS_TEST_TMPDIR
  unset GH_TOKEN GITHUB_TOKEN GH_REPO GH_WRAPPED AGENT_QUEUE_ITEM
  cd "$BATS_TEST_TMPDIR"
}

token() { tail -n 1 "$BATS_TEST_TMPDIR/real.log" | cut -d'|' -f1; }
bucket() { tail -n 1 "$GH_CALLS_DIR"/*.tsv | cut -f2; }

@test "a run read with -R goes out on the owner's App token, args untouched, logged as app" {
  run "$WRAP" run view 5 -R acme/x --json status
  assert_success
  assert_equal "$(tail -n 1 "$BATS_TEST_TMPDIR/real.log")" 'tok-acme|run view 5 -R acme/x --json status'
  assert_equal "$(bucket)" app:acme
}

@test "writes, @me and the text views stay on the human's token" {
  for args in 'pr create -R acme/x --title t' 'pr merge 5 -R acme/x --squash' \
    'pr list --author @me -R acme/x --json number' 'pr view 5 -R acme/x' 'issue view 3 -R acme/x' \
    'search prs --owner acme' 'repo clone acme/x'; do
    # shellcheck disable=SC2086
    "$WRAP" $args
    assert_equal "$(token)" none
    assert_equal "$(bucket)" user
  done
}

@test "gh api: a GET under repos/<owner>/ is routed; a write, graphql, rate_limit or user path is not" {
  "$WRAP" api repos/acme/x/actions/runs --paginate -q '.total_count'
  assert_equal "$(token)" tok-acme
  "$WRAP" api /repos/acme/x/pulls/5/files
  assert_equal "$(token)" tok-acme
  "$WRAP" api -X GET repos/acme/x/issues -f state=open
  assert_equal "$(token)" tok-acme
  for args in '-X POST repos/acme/x/issues' 'repos/acme/x/issues -f title=t' '--method=PATCH repos/acme/x' \
    'graphql -f query=q' 'rate_limit' 'user' 'orgs/acme/members' '--hostname ghe.example.com repos/acme/x'; do
    # shellcheck disable=SC2086
    "$WRAP" api $args
    assert_equal "$(token)" none
  done
}

@test "gh api {owner} placeholders take GH_REPO's owner, as gh fills them" {
  GH_REPO=acme/x "$WRAP" api 'repos/{owner}/{repo}/actions/runs'
  assert_equal "$(token)" tok-acme
}

@test "with no -R the directory's lone GitHub origin names the owner; a second GitHub remote or a set-default does not" {
  git init -q repo && cd repo
  git remote add origin git@github.com:acme/x.git
  "$WRAP" run list --limit 3
  assert_equal "$(token)" tok-acme
  git remote add upstream https://github.com/other/x.git
  "$WRAP" run list --limit 3
  assert_equal "$(token)" none
  git remote remove upstream
  git config remote.origin.gh-resolved base
  "$WRAP" run list --limit 3
  assert_equal "$(token)" none
}

@test "a PR URL names its repo over the directory's origin" {
  git init -q repo && cd repo
  git remote add origin git@github.com:other/x.git
  "$WRAP" pr view https://github.com/acme/x/pull/5 --json state
  assert_equal "$(token)" tok-acme
}

@test "an owner with no installation stays on the user; a failed mint is logged as user:app-error" {
  "$WRAP" run view 5 -R nobody/x
  assert_equal "$(token)" none
  assert_equal "$(bucket)" user
  "$WRAP" run view 5 -R broken/x
  assert_equal "$(token)" none
  assert_equal "$(bucket)" user:app-error
}

@test "a caller's own GH_TOKEN wins and is logged as env" {
  GH_TOKEN=mine "$WRAP" run view 5 -R acme/x
  assert_equal "$(token)" mine
  assert_equal "$(bucket)" env
}

@test "the exit code and stdin pass through; the log row carries rc, caller script and item" {
  printf '#!/usr/bin/env bash\n"%s" pr edit 5 -R acme/x --body-file -\n' "$WRAP" > "$BATS_TEST_TMPDIR/land-thing"
  chmod +x "$BATS_TEST_TMPDIR/land-thing"
  REAL_RC=3 AGENT_QUEUE_ITEM=ship run bash -c "echo body | '$BATS_TEST_TMPDIR/land-thing'"
  assert_failure 3
  assert_equal "$(cat "$BATS_TEST_TMPDIR/stdin.log")" body
  run cut -f2- "$GH_CALLS_DIR/$(date +%F).tsv"
  assert_output $'user\t3\tland-thing\tship\tpr edit 5 -R acme/x --body-file -'
}

@test "with GH_REAL unset it runs the next gh on PATH, skipping itself" {
  unset GH_REAL
  mkdir -p "$BATS_TEST_TMPDIR/wrap" "$BATS_TEST_TMPDIR/real"
  ln -s "$WRAP" "$BATS_TEST_TMPDIR/wrap/gh"
  cp "$STUB/real-gh" "$BATS_TEST_TMPDIR/real/gh"
  PATH="$BATS_TEST_TMPDIR/wrap:$BATS_TEST_TMPDIR/real:$PATH" run gh run view 5 -R acme/x
  assert_success
  assert_equal "$(tail -n 1 "$BATS_TEST_TMPDIR/real.log")" 'tok-acme|run view 5 -R acme/x'
  PATH="$BATS_TEST_TMPDIR/wrap:/usr/bin/nonexistent" run -127 "$BASH" "$BATS_TEST_TMPDIR/wrap/gh" --version
  assert_output --partial 'no gh on PATH besides this wrapper'
}

# gh-app against a stub curl: the JWT is signed with a throwaway key, and the stub answers by URL.
app_setup() {
  openssl genrsa -out "$BATS_TEST_TMPDIR/key.pem" 2048 2>/dev/null
  printf 'GH_APP_ID=123\nGH_APP_KEY_FILE=%s\n' "$BATS_TEST_TMPDIR/key.pem" > "$BATS_TEST_TMPDIR/fleet.env"
  export GH_APP_CONFIG="$BATS_TEST_TMPDIR/fleet.env" GH_APP_CACHE="$BATS_TEST_TMPDIR/cache" GH_APP_API=https://api.test
  cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/curl.log"
cat >> "$BATS_TEST_TMPDIR/curl.stdin"
case "${@: -1}" in
  */app/installations\?*) echo '[{"id":7,"account":{"login":"Acme"}},{"id":8,"account":{"login":"picky"}}]' ;;
  */installations/7/access_tokens) echo '{"token":"ghs_one","repository_selection":"all"}' ;;
  */installations/8/access_tokens) echo '{"token":"ghs_two","repository_selection":"selected"}' ;;
  *) exit 22 ;;
esac
SH
  chmod +x "$STUB/curl"
  rm -f "$STUB/gh-app"
}

@test "gh-app: no config is off (exit 2) and calls nothing" {
  GH_APP_CONFIG=/nonexistent run "$GHAPP" token acme
  assert_failure 2
  [ ! -f "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "gh-app: mints once per owner and reuses the cached token; the JWT never reaches argv" {
  app_setup
  run "$GHAPP" token ACME
  assert_success
  assert_output ghs_one
  run "$GHAPP" token acme
  assert_output ghs_one
  assert_equal "$(grep -c access_tokens "$BATS_TEST_TMPDIR/curl.log")" 1
  refute grep -q Bearer "$BATS_TEST_TMPDIR/curl.log"
  grep -q '^header = "Authorization: Bearer ey' "$BATS_TEST_TMPDIR/curl.stdin"
  # the JWT names the App and is signed by its key
  jwt=$(grep -m1 -o 'Bearer [^"]*' "$BATS_TEST_TMPDIR/curl.stdin" | cut -d' ' -f2)
  body=$(cut -d. -f2 <<<"$jwt" | tr -- '-_' '+/')
  while [ $(( ${#body} % 4 )) -ne 0 ]; do body="$body="; done
  assert_equal "$(base64 -d <<<"$body" | jq -r .iss)" 123
}

@test "gh-app: an owner with no installation or a selected-repos one exits 2; a failed mint exits 1" {
  app_setup
  run "$GHAPP" token nobody
  assert_failure 2
  run "$GHAPP" token picky
  assert_failure 2
  assert_output --partial 'selected repos only'
  rm -rf "$GH_APP_CACHE"
  printf '#!/bin/sh\nexit 22\n' > "$STUB/curl"
  run "$GHAPP" token acme
  assert_failure 1
}

@test "the wrapper and the real gh-app together: a routed read carries the minted token" {
  app_setup
  ln -s "$GHAPP" "$STUB/gh-app"
  "$WRAP" run view 5 -R acme/x
  assert_equal "$(token)" ghs_one
  assert_equal "$(bucket)" app:acme
}
