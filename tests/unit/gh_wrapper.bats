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
case "$*" in 'api rate_limit'*) [ -f "$BATS_TEST_TMPDIR/rate" ] && cat "$BATS_TEST_TMPDIR/rate"; exit 0 ;; esac
if [ -n "${DENY:-}" ] && [ "${GH_TOKEN:-}" = tok-acme ]; then echo "HTTP 401: $DENY" >&2; exit 1; fi
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
    'search prs --owner acme' 'repo clone acme/x' 'pr checks 5 -R acme/x --watch'; do
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

@test "a GH_HOST other than github.com is never routed" {
  GH_HOST=ghe.example.com "$WRAP" run view 5 -R acme/x
  assert_equal "$(token)" none
}

@test "a read the App's token is refused for reruns on the user and is logged as app-denied; other errors show once" {
  DENY='Bad credentials' run "$WRAP" run view 5 -R acme/x
  assert_success
  assert_equal "$(tail -n 2 "$BATS_TEST_TMPDIR/real.log" | cut -d'|' -f1 | paste -sd,)" tok-acme,none
  assert_equal "$(bucket)" user:app-denied
  refute_output --partial 'Bad credentials'
  REAL_RC=1 run "$WRAP" run view 6 -R acme/x
  assert_failure 1
  assert_equal "$(grep -c 'run view 6' "$BATS_TEST_TMPDIR/real.log")" 1
  assert_equal "$(bucket)" app:acme
}

@test "the log blanks bodies, fields and headers, keeps only the subcommand of secret, and is yours only" {
  "$WRAP" secret set TOKEN --body s3cr3t -R acme/x
  "$WRAP" api -X POST repos/acme/x/issues -f title=hunter2 -Fbody=x -H 'Authorization: token y' --raw-field=k=v
  "$WRAP" pr create -R acme/x -b 'the body' --title t
  run cut -f6 "$GH_CALLS_DIR/$(date +%F).tsv"
  assert_output $'secret set\napi -X POST repos/acme/x/issues -f _ -F_ -H _ --raw-field=_\npr create -R acme/x -b _ --title t'
  assert_equal "$(stat -c %a "$GH_CALLS_DIR/$(date +%F).tsv")" 600
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
  cp "$STUB/curl" "$BATS_TEST_TMPDIR/good-curl"
  printf '#!/bin/sh\nexit 22\n' > "$STUB/curl"
  run "$GHAPP" token acme
  assert_failure 1
  # inside the backoff a token call fails at once, without curl; status clears it
  cp "$BATS_TEST_TMPDIR/good-curl" "$STUB/curl"
  : > "$BATS_TEST_TMPDIR/curl.log"
  run "$GHAPP" token acme
  assert_failure 1
  assert_output --partial 'gh-app status retries now'
  [ ! -s "$BATS_TEST_TMPDIR/curl.log" ]
  run "$GHAPP" status
  run "$GHAPP" token acme
  assert_success
  assert_output ghs_one
}

@test "the wrapper and the real gh-app together: a routed read carries the minted token" {
  app_setup
  ln -s "$GHAPP" "$STUB/gh-app"
  "$WRAP" run view 5 -R acme/x
  assert_equal "$(token)" ghs_one
  assert_equal "$(bucket)" app:acme
}

@test "a sandboxed HOME never reaches GitHub, so a test that forgot its gh stub acts on nothing (ar-1892)" {
  mkdir -p "$BATS_TEST_TMPDIR/home"
  HOME="$BATS_TEST_TMPDIR/home" run "$WRAP" workflow run hd.yml -R acme/x
  assert_failure 3
  assert_output --partial "a sandboxed caller never reaches GitHub"
  [ ! -e "$BATS_TEST_TMPDIR/real.log" ]
  # NEGATIVE CONTROL: the account's own home reaches the real gh
  HOME="$(getent passwd "$(id -un)" | cut -d: -f6)" run "$WRAP" workflow run hd.yml -R acme/x
  assert_success
  assert_equal "$(tail -n 1 "$BATS_TEST_TMPDIR/real.log")" 'none|workflow run hd.yml -R acme/x'
}

# The shared budget: a background caller's read waits when few calls are left. The caller is the
# script that ran gh, so each case runs the wrapper from a script named like the real one.
as_caller() { # <script name> <gh args...>
  local name="$1"; shift
  printf '#!/usr/bin/env bash\n"%s" "$@"\n' "$WRAP" > "$BATS_TEST_TMPDIR/$name"
  chmod +x "$BATS_TEST_TMPDIR/$name"
  bash "$BATS_TEST_TMPDIR/$name" "$@"
}
gh_calls() { { grep -vc '^none|api rate_limit' "$BATS_TEST_TMPDIR/real.log" || true; } 2>/dev/null; }

@test "budget: a listed caller's read under the reserve waits, logged as deferred, and never reaches gh" {
  echo "40 $(( $(date +%s) + 1800 ))" > "$BATS_TEST_TMPDIR/rate"
  run -75 as_caller schedules-sync run view 5 -R other/x --json status
  assert_output --partial 'waits for the reset'
  assert_equal "$(gh_calls)" 0
  assert_equal "$(bucket)" user:deferred
}

@test "budget: above the reserve, or once the reset has passed, the same read goes through" {
  echo "4000 $(( $(date +%s) + 1800 ))" > "$BATS_TEST_TMPDIR/rate"
  run as_caller ci-failures.py api repos/other/x/actions/runs/5
  assert_success
  assert_equal "$(gh_calls)" 1
  rm -f "$GH_CALLS_DIR/budget"
  echo "40 $(( $(date +%s) - 5 ))" > "$BATS_TEST_TMPDIR/rate"
  run as_caller fleet-sessions repo view --json defaultBranchRef
  assert_success
}

@test "budget: writes, graphql, other callers and the rate_limit probe never wait, however low the budget" {
  echo "0 $(( $(date +%s) + 1800 ))" > "$BATS_TEST_TMPDIR/rate"
  run as_caller schedules-sync pr merge 5 -R other/x --squash
  assert_success
  run as_caller schedules-sync api -X POST repos/other/x/issues -f title=t
  assert_success
  run as_caller schedules-sync api graphql -f query=q
  assert_success
  run as_caller schedules-sync api rate_limit
  assert_success
  run as_caller schedules-sync api -H 'Accept: application/json' rate_limit
  assert_success
  run as_caller gate-line.py run view 5 -R other/x --json status
  assert_success
  run as_caller agent-land pr checks 5 -R other/x
  assert_success
}

@test "budget: one reading is shared, renewed only when older than GH_BUDGET_STALE_S, and an unreadable one never blocks" {
  echo "40 $(( $(date +%s) + 1800 ))" > "$BATS_TEST_TMPDIR/rate"
  run -75 as_caller fleet-assess run list -R other/x
  echo "4000 $(( $(date +%s) + 1800 ))" > "$BATS_TEST_TMPDIR/rate"
  run -75 as_caller fleet-assess run list -R other/x      # the reading is still fresh: no second probe
  GH_BUDGET_STALE_S=0 run as_caller fleet-assess run list -R other/x
  assert_success
  rm -f "$GH_CALLS_DIR/budget" "$BATS_TEST_TMPDIR/rate"  # the probe prints nothing: unknown, so let it through
  run as_caller fleet-assess run list -R other/x
  assert_success
  assert_equal "$(cut -d' ' -f1,2 "$GH_CALLS_DIR/budget")" '- -'
}

@test "budget: a call on the App's token spends another budget and is never deferred" {
  echo "0 $(( $(date +%s) + 1800 ))" > "$BATS_TEST_TMPDIR/rate"
  run as_caller schedules-sync run view 5 -R acme/x --json status
  assert_success
}

@test "budget: a conditional read (api -i) from a listed caller waits like any other; a process that loses the renewal lock uses the old reading" {
  echo "40 $(( $(date +%s) + 1800 ))" > "$BATS_TEST_TMPDIR/rate"
  run -75 as_caller schedules-sync api -i repos/other/x/actions/runs/5
  mkdir -p "$GH_CALLS_DIR"
  echo "40 $(( $(date +%s) + 1800 )) 1" > "$GH_CALLS_DIR/budget"   # stale
  exec 8>"$GH_CALLS_DIR/budget.lock"; flock -n 8                    # another process holds the renewal
  run -75 as_caller schedules-sync api repos/other/x/pulls/5
  exec 8>&-
}
