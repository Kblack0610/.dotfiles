#!/usr/bin/env bats
# agent-hold: the durable fleet-wide pause. `check` is what a resource gate (run.sh's slot
# helper) calls, so its exit code is the contract a shell loop obeys.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  HOLD="$REPO_ROOT/.local/bin/agent-hold"
  export AGENT_HOLD_DIR="$HOME/.agent/holds"
  # Record pages instead of sending them.
  NOTIFY_LOG="$SANDBOX/notify.log"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$NOTIFY_LOG" > "$SANDBOX/bin/agent-notify"
  chmod +x "$SANDBOX/bin/agent-notify"
}

@test "check is free (exit 0) when nothing is held" {
  run "$HOLD" check unity-tests
  assert_success
  assert_output ''
}

@test "set then check reports the hold and exits 1" {
  run "$HOLD" set unity-tests --by coordinator "96 C, too many editors"
  assert_success
  run "$HOLD" check unity-tests
  assert_failure 1
  assert_output --partial 'by coordinator: 96 C, too many editors'
}

@test "aged names each standing hold set a day ago or longer, pages high and exits 1, and releases none (ar-4471, ar-4645)" {
  run "$HOLD" aged
  assert_success
  back() { sed -i "s/^since: .*/since: $(date -d "-$2 days" +%Y-%m-%dT%H:%M:%S%z)/" "$AGENT_HOLD_DIR/$1"; }
  "$HOLD" set fresh --by human --until '+12 hours' "new"
  "$HOLD" set old --kind resource --by fleet-dispatch "kept on purpose"
  back old 2
  run "$HOLD" aged
  assert_failure 1
  assert_line --index 0 --regexp '^old: held 2d, since .* by fleet-dispatch: kept on purpose$'
  assert_line --index 1 --partial '1 hold(s) set 1 day(s) ago or longer'
  assert_line --index 2 'page: high'
  refute_output --partial 'fresh'
  run "$HOLD" check old
  assert_failure 1
  run "$HOLD" aged --days 3
  assert_success
  # A human hold ends by its until, so its age never pages (ar-6059); one with no until line (a
  # file from before until) is the human's to end, so it pages.
  back fresh 2
  run "$HOLD" aged --days 1
  refute_output --partial 'fresh'
  sed -i '/^until: /d' "$AGENT_HOLD_DIR/fresh"
  run "$HOLD" aged
  assert_failure 1
  assert_line --index 0 --partial 'fresh: held 2d'
  # An empty since is unreadable, so it shows: date -d "" alone reads as today.
  sed -i "s/^since: .*/since: /" "$AGENT_HOLD_DIR/fresh"
  run "$HOLD" aged --days 3
  assert_failure 1
  assert_line --index 0 --partial 'fresh: held '
  assert_line --index 0 --partial 'since an unreadable time by human: new'
}

@test "aged leaves out a load hold and a claim however old, since neither waits on the human (ar-4645)" {
  back() { sed -i "s/^since: .*/since: $(date -d "-$2 days" +%Y-%m-%dT%H:%M:%S%z)/" "$AGENT_HOLD_DIR/$1"; }
  "$HOLD" set unity --by fleet-pace "96 C"
  "$HOLD" claim mac-desktop --by agent-7 "store forms"
  back unity 2; back mac-desktop 2
  run "$HOLD" aged
  assert_success
  assert_output ''
}

@test "set --by human needs --until at most 24h; past it check and list read it released and list --expired names it (ar-6059)" {
  run "$HOLD" set critical --kind resource --by human "lockdown"
  assert_failure 2
  assert_output --partial 'give --until'
  for u in '+25 hours' '-1 hour' 'not a time'; do
    run "$HOLD" set critical --kind resource --by human --until "$u" "lockdown"
    assert_failure 2
  done
  [ ! -e "$AGENT_HOLD_DIR/critical" ]
  run "$HOLD" set critical --kind resource --by human --until '+23 hours' "lockdown"
  assert_success
  run "$HOLD" show critical
  assert_line --regexp '^until: [0-9]{4}-'
  run "$HOLD" check critical --no-caller
  assert_failure 1
  run "$HOLD" list
  assert_output --partial 'critical'
  run "$HOLD" list --expired
  assert_output ''
  # An agent's hold may end on its own too.
  "$HOLD" set unity --by fleet-pace --until '+1 hour' "hot"
  # Past its until it reads released; the file stays for the release that restores what it lowered.
  sed -i "s/^until: .*/until: $(date -d '-1 minute' +%Y-%m-%dT%H:%M:%S%z)/" "$AGENT_HOLD_DIR/critical"
  run "$HOLD" check critical --no-caller
  assert_success
  assert_output --partial 'expired: critical'
  run "$HOLD" list
  refute_output --partial 'critical'
  assert_output --partial 'unity'
  run "$HOLD" list --kind resource
  assert_output ''
  run "$HOLD" list --expired
  assert_output --regexp '^critical	'
  refute_output --partial 'unity'
  # An until no date reads has passed.
  sed -i 's/^until: .*/until: soon/' "$AGENT_HOLD_DIR/unity"
  run "$HOLD" check unity --no-caller
  assert_success
  # An expired human hold is over: an agent may set the resource afresh, with its own since.
  sed -i 's/^since: .*/since: 2026-11-01T00:00:00-0800/' "$AGENT_HOLD_DIR/critical"
  run "$HOLD" set critical --kind resource --by coordinator "maintenance"
  assert_success
  run "$HOLD" show critical
  assert_line 'by: coordinator'
  refute_output --partial 'since: 2026-11-01'
  refute_output --partial 'until:'
  "$HOLD" release critical
  [ ! -e "$AGENT_HOLD_DIR/critical" ]
  # keep is gone: the until replaces it.
  run "$HOLD" keep critical --ask x
  assert_failure 2
}

@test "from an agent session, set --by human takes the human's words agent-ask said finds in the transcript (ar-6059)" {
  # A stub agent-ask: said passes only for the words in $SANDBOX/said, and logs its arguments.
  cat > "$SANDBOX/bin/agent-ask" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$SANDBOX/said.log"
[ "\$1" = said ] || exit 2
[ "\$4" = "\$(cat "$SANDBOX/said")" ] || { echo "no words of the human's contain: \$4" >&2; exit 1; }
STUB
  chmod +x "$SANDBOX/bin/agent-ask"
  export AGENT_ASK="$SANDBOX/bin/agent-ask"
  echo 'hold critical till tomorrow' > "$SANDBOX/said"
  # No quote from a session: refused, and nothing is written.
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$HOLD" set critical --by human --until '+12 hours' "lockdown"
  assert_failure 2
  assert_output --partial "--quote '<their words>'"
  # Words the human did not type: refused.
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$HOLD" set critical --by human --until '+12 hours' --quote 'lock critical down' "lockdown"
  assert_failure 1
  assert_output --partial 'no words of the human'
  [ ! -e "$AGENT_HOLD_DIR/critical" ]
  # --quote needs --by human, from inside a session.
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$HOLD" set critical --by agent-7 --quote 'hold critical till tomorrow' "lockdown"
  assert_failure 2
  run "$HOLD" set critical --by human --until '+12 hours' --quote 'hold critical till tomorrow' "lockdown"
  assert_failure 2
  # Words the human did type, but not about this hold: refused before the transcript is read.
  echo 'yes, the critical-path one' > "$SANDBOX/said"
  : > "$SANDBOX/said.log"
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$HOLD" set critical --by human --until '+12 hours' --quote 'yes, the critical-path one' "lockdown"
  assert_failure 1
  assert_output --partial 'does not name critical'
  [ ! -s "$SANDBOX/said.log" ]
  echo 'hold critical till tomorrow' > "$SANDBOX/said"
  [ ! -e "$AGENT_HOLD_DIR/critical" ]
  # Their words: set, with the words on the hold, checked over the last hour.
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$HOLD" set critical --by human --until '+12 hours' --quote 'hold critical till tomorrow' "lockdown"
  assert_success
  run "$HOLD" show critical
  assert_line 'by: human'
  assert_line 'quote: hold critical till tomorrow'
  grep -q '^said --since @[0-9]* hold critical till tomorrow$' "$SANDBOX/said.log"
  # A re-set needs words that pass again; refused, the hold stays as it was.
  echo 'other words' > "$SANDBOX/said"
  run env AGENT_QUEUE_ITEM=ar-1 "$HOLD" set critical --by human --until '+12 hours' --quote 'hold critical till tomorrow' "lockdown, longer"
  assert_failure 1
  run "$HOLD" show critical
  assert_line 'reason: lockdown'
}

@test "grant on the human's hold takes the human's grant answer naming the hold and each name, recorded beside it; an agent's hold grants as before (ar-6046)" {
  "$HOLD" set critical --kind resource --by human --until '+23 hours' "lockdown"
  sed -i "s/^since: .*/since: $(date -d '-4 days' +%Y-%m-%dT%H:%M:%S%z)/" "$AGENT_HOLD_DIR/critical"
  mkdir -p "$SANDBOX/asks"
  printf '#!/usr/bin/env bash\n[ "$1" = show ] && cat "%s/asks/$2"\n' "$SANDBOX" > "$SANDBOX/bin/agent-ask"
  chmod +x "$SANDBOX/bin/agent-ask"
  export AGENT_ASK="$SANDBOX/bin/agent-ask"
  ask() { printf 'question: %s\nanswer: %s\nanswered_by: %s\nanswered_at: %s\ncontext: \n' "$2" "$3" "$4" "$(date -d "-${5:-1} hours" +%Y-%m-%dT%H:%M:%S%z)" > "$SANDBOX/asks/$1"; }
  # No ask: an agent's own word is refused.
  run "$HOLD" grant critical hc-1
  assert_failure 1
  assert_output --partial 'only the human grants'
  # Negative controls: answered hold, answered by an agent, about another hold, a name it does not
  # say, answered before since, a name only inside a longer id, a dot read as any character, no ask.
  ask a1 "May hc-1 run under the critical hold?" hold human
  ask a2 "May hc-1 run under the critical hold?" grant agent
  ask a3 "May hc-1 run under the critical-dns hold?" grant human
  ask a4 "May hc-1 run under the critical hold?" grant human
  ask a5 "May hc-1 run under the critical hold?" grant human 100
  ask a6 "May hc-10 run under the critical hold?" grant human
  ask a7 "May v1x2 run under the critical hold?" grant human
  for args in "a1 hc-1" "a2 hc-1" "a3 hc-1" "a4 hc-1 hc-2" "a5 hc-1" "a6 hc-1" "a7 v1.2" "missing hc-1"; do
    read -ra a <<<"$args"
    run "$HOLD" grant critical --ask "${a[@]}"
    assert_failure 1
  done
  run "$HOLD" show critical
  assert_line 'granted: '
  refute_output --partial 'granted_ask'
  # The human's grant answer naming both: each name is granted and carries the ask.
  ask ok "May hc-1 and ar-5 run under the critical hold?" grant human
  run "$HOLD" grant critical --ask ok hc-1 ar-5
  assert_success
  assert_output 'granted: critical for hc-1,ar-5 (ask ok)'
  run "$HOLD" show critical
  assert_line 'granted: hc-1,ar-5'
  assert_line 'granted_ask: hc-1=ok,ar-5=ok'
  run "$HOLD" check critical --no-caller --for ar-5
  assert_success
  # A name granted again under a newer ask takes that ask.
  ask ok2 "May hc-1 run under the critical hold?" grant human
  run "$HOLD" grant critical --ask ok2 hc-1
  assert_success
  run "$HOLD" show critical
  assert_line 'granted: hc-1,ar-5'
  assert_line 'granted_ask: ar-5=ok,hc-1=ok2'
  # A re-set by an agent would hand the hold to a setter whose grants need no ask: refused.
  run "$HOLD" set critical --kind resource --by coordinator "lockdown"
  assert_failure 1
  assert_output --partial 'the human set critical'
  run "$HOLD" show critical
  assert_line 'by: human'
  # A re-set drops the grants and the asks with them.
  "$HOLD" set critical --kind resource --by human --until '+23 hours' "lockdown, reworded"
  run "$HOLD" show critical
  assert_line 'granted: '
  refute_output --partial 'granted_ask'
  # A hold an agent set grants on the caller's word, as before.
  "$HOLD" set chores --kind resource --by agent-7 "parked"
  run "$HOLD" grant chores hc-3
  assert_success
  run "$HOLD" show chores
  assert_line 'granted: hc-3'
  assert_line 'granted_ask: '
}

@test "a hold on one resource leaves another free" {
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" check gpu
  assert_success
}

@test "list prints one TSV row per hold" {
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" set gpu --by d "training"
  run "$HOLD" list
  assert_success
  assert_line --partial $'unity-tests\t'
  assert_line --partial $'\td\ttraining'
  [ "${#lines[@]}" -eq 2 ]
}

@test "a hold is load unless --kind says resource (dispatch defaults to resource), and list --kind filters (ar-2605)" {
  "$HOLD" set unity --by c "96 C"
  "$HOLD" set deskslim-1-ram --by d --kind resource "bad RAM; release after memtest"
  "$HOLD" set dispatch --by g "maintenance"
  "$HOLD" claim mac-desktop --by e "store form"
  # holds written before kinds existed read as the kind set would give them
  printf 'resource: old\nsince: x\nby: f\nroster: \ngranted: \nreason: legacy\n' > "$AGENT_HOLD_DIR/old"
  printf 'resource: dispatch\nsince: x\nby: f\nroster: \ngranted: \nreason: legacy\n' > "$AGENT_HOLD_DIR/dispatch"
  run "$HOLD" show unity
  assert_line 'kind: load'
  run "$HOLD" list --kind load
  assert_success
  assert_line --partial $'old\t'
  assert_line --partial $'unity\t'
  [ "${#lines[@]}" -eq 2 ]
  run "$HOLD" list --kind resource
  assert_line --partial $'deskslim-1-ram\t'
  assert_line --partial $'dispatch\t'
  [ "${#lines[@]}" -eq 2 ]
  run "$HOLD" list --kind claim
  assert_output --partial $'mac-desktop\t'
  [ "${#lines[@]}" -eq 1 ]
  run "$HOLD" list
  [ "${#lines[@]}" -eq 5 ]
  # a re-set writes the kind it is given, so a load hold on a resource once held for RAM is load
  "$HOLD" set deskslim-1-ram --by d "hot"
  run "$HOLD" show deskslim-1-ram
  assert_line 'kind: load'
  run "$HOLD" set x --kind heat "why"
  assert_failure 2
  run "$HOLD" list --kind heat
  assert_failure 2
  run "$HOLD" list --kind load extra
  assert_failure 2
}

@test "set refuses a flag with no value instead of looping on it" {
  run timeout 5 "$HOLD" set x --roster
  assert_failure 2
  assert_output --partial '--roster needs a value'
}

@test "release frees the resource and prints the roster for GO" {
  "$HOLD" set unity-tests --by c --roster agent-19,agent-21 "hot"
  run "$HOLD" release unity-tests
  assert_success
  assert_line 'roster: agent-19,agent-21'
  run "$HOLD" check unity-tests
  assert_success
}

@test "set and release both page low: the overseer acts on holds itself" {
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" release unity-tests
  run cat "$NOTIFY_LOG"
  assert_line --index 0 --partial '-p low -t hold: unity-tests'
  assert_line --index 1 --partial '-p low -t go: unity-tests'
}

@test "release of a resource that is not held fails" {
  run "$HOLD" release unity-tests
  assert_failure 1
}

@test "set without a reason is refused" {
  run "$HOLD" set unity-tests
  assert_failure 2
  [ ! -e "$AGENT_HOLD_DIR/unity-tests" ]
}

@test "a resource name cannot escape the hold dir" {
  run "$HOLD" set ../escape "x"
  assert_failure 2
  run "$HOLD" check ../escape
  assert_failure 2
  [ ! -e "$HOME/.agent/escape" ]
}

# A grant is GO as state. Caller identity is callers: the Claude session id, the tmux window,
# here (no TMUX in the sandbox) the working directory's basename.
as_session() { mkdir -p "$SANDBOX/$1" && cd "$SANDBOX/$1"; }

@test "grant on a resource that is not held fails" {
  run "$HOLD" grant unity agent-1
  assert_failure 1
  assert_output --partial 'not held'
}

@test "a granted session passes check; an ungranted one is still held" {
  "$HOLD" set unity --by shepherd "hot"
  run "$HOLD" grant unity agent-1
  assert_success
  as_session agent-1
  run "$HOLD" check unity
  assert_success
  as_session agent-2
  run "$HOLD" check unity
  assert_failure 1
}

@test "a grant matches a whole session name, not a prefix" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1
  as_session agent-11
  run "$HOLD" check unity
  assert_failure 1
}

@test "grants merge across calls without duplicates" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1 agent-2
  "$HOLD" grant unity agent-2 agent-3
  run "$HOLD" show unity
  assert_output --partial 'granted: agent-1,agent-2,agent-3'
  run "$HOLD" list
  assert_output --partial '(granted: agent-1,agent-2,agent-3)'
}

@test "a fresh set drops every earlier grant" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity agent-1
  "$HOLD" set unity --by shepherd "hot again"
  as_session agent-1
  run "$HOLD" check unity
  assert_failure 1
}

@test "a re-set keeps since, so hold-age ages the hold from its first set; a release starts it afresh (ar-5236)" {
  "$HOLD" set critical --kind resource --by coordinator "lockdown"
  first="$(date -d '-3 days' +%Y-%m-%dT%H:%M:%S%z)"
  sed -i "s/^since: .*/since: $first/" "$AGENT_HOLD_DIR/critical"
  "$HOLD" set critical --kind resource --by coordinator "lockdown, reworded"
  run "$HOLD" show critical
  assert_output --partial "since: $first"
  assert_output --partial 'reason: lockdown, reworded'
  run "$HOLD" aged
  assert_failure 1
  assert_output --partial 'critical: held'
  "$HOLD" release critical
  "$HOLD" set critical --kind resource --by coordinator "lockdown again"
  run "$HOLD" show critical
  refute_output --partial "since: $first"
}

@test "a re-set as another kind, or over a since no date reads, starts since afresh" {
  "$HOLD" set unity --by fleet-pace "hot"
  sed -i 's/^since: .*/since: 2026-11-01T00:00:00-0800/' "$AGENT_HOLD_DIR/unity"
  "$HOLD" set unity --kind resource --by human --until '+23 hours' "maintenance"
  run "$HOLD" show unity
  refute_output --partial 'since: 2026-11-01T00:00:00-0800'
  sed -i 's/^since: .*/since: /' "$AGENT_HOLD_DIR/unity"
  "$HOLD" set unity --kind resource --by human --until '+23 hours' "maintenance, longer"
  run "$HOLD" show unity
  assert_output --regexp 'since: [0-9]{4}-'
}

@test "a set over a claim starts its own since, not the claim's" {
  "$HOLD" claim mac-desktop --by agent-1 "store forms"
  sed -i 's/^since: .*/since: 2026-11-01T00:00:00-0800/' "$AGENT_HOLD_DIR/mac-desktop"
  "$HOLD" set mac-desktop --kind resource --by human --until '+23 hours' "maintenance"
  run "$HOLD" show mac-desktop
  refute_output --partial 'since: 2026-11-01T00:00:00-0800'
}

@test "grant takes row, epic and plan ids and keeps since; a name with a space is refused (ar-5236)" {
  "$HOLD" set critical --kind resource --by coordinator "lockdown"
  sed -i 's/^since: .*/since: 2026-11-20T16:10:54-0800/' "$AGENT_HOLD_DIR/critical"
  run "$HOLD" grant critical hc-952 ar-4938 pasted-content-id-9f60-we-optimized-rossum
  assert_success
  run "$HOLD" show critical
  assert_output --partial 'since: 2026-11-20T16:10:54-0800'
  assert_output --partial 'granted: hc-952,ar-4938,pasted-content-id-9f60-we-optimized-rossum'
  run "$HOLD" grant critical 'hc-953 hc-954'
  assert_failure 2
  assert_output --partial 'no comma, space or ='
  # A row id is no session: a caller is still held unless it is granted by a name of its own.
  as_session agent-1
  run "$HOLD" check critical
  assert_failure 1
}

@test "check --for passes on a granted row, epic or plan and names each; ungranted ids and --no-caller stay held" {
  "$HOLD" set critical --kind resource --by coordinator "lockdown"
  "$HOLD" grant critical hc-1 ar-5235 plan-x
  run "$HOLD" check critical --no-caller --for hc-2 plan-x hc-1
  assert_success
  assert_output --partial 'granted: critical for hc-1 plan-x'
  run "$HOLD" check critical --no-caller --for hc-2 ar-9
  assert_failure 1
  # --no-caller: a granted session id is not asked about, only the ids named.
  as_session agent-1
  "$HOLD" grant critical agent-1
  run "$HOLD" check critical --no-caller --for hc-2
  assert_failure 1
  run "$HOLD" check critical
  assert_success
}

# A tmux pane, faked: the stub answers display-message only when asked of $STUB_PANE, so a
# caller that asks without -t "$TMUX_PANE" gets no name.
in_pane() { # <session> <window index> <windows in the session>
  export TMUX="$SANDBOX/tmp/hub,1,0" TMUX_PANE=%5 STUB_PANE=%5 STUB_S="$1" STUB_W="$2" STUB_N="$3"
}
tmux_stub() {
  tmux_script <<'STUB'
[ "$1 $2 $3" = "display-message -p -t" ] && [ "$4" = "$STUB_PANE" ] || exit 1
printf '%s\t%s\t%s\n' "$STUB_S" "$STUB_W" "$STUB_N"
STUB
}

@test "a grant names one window of a many-window session; its bare name matches none of them (ar-2836)" {
  tmux_stub
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity hub/dotfiles:3 dotfiles:2
  in_pane dotfiles 3 4
  run "$HOLD" check unity
  assert_success
  assert_output 'granted: unity for hub/dotfiles:3'
  in_pane dotfiles 2 4
  run "$HOLD" check unity
  assert_success
  in_pane dotfiles 1 4
  run "$HOLD" check unity
  assert_failure 1
  # the session's bare name used to let every window through
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity dotfiles
  in_pane dotfiles 3 4
  run "$HOLD" check unity
  assert_failure 1
  # a one-window session still answers to its bare name
  "$HOLD" grant unity agent-1
  in_pane agent-1 1 1
  run "$HOLD" check unity
  assert_success
}

@test "a grant to a Claude session id lets that session through, wherever it runs" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity 0d1e-aaaa
  as_session somewhere
  run env CLAUDE_CODE_SESSION_ID=0d1e-aaaa "$HOLD" check unity
  assert_success
  run env CLAUDE_CODE_SESSION_ID=0d1e-bbbb "$HOLD" check unity
  assert_failure 1
}

@test "check --no-caller asks as no session: the asker's grant and claim do not count" {
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity 0d1e-aaaa
  run env CLAUDE_CODE_SESSION_ID=0d1e-aaaa "$HOLD" check unity --no-caller
  assert_failure 1
  "$HOLD" release unity
  CLAUDE_CODE_SESSION_ID=0d1e-aaaa "$HOLD" claim mac-desktop "store form"
  run env CLAUDE_CODE_SESSION_ID=0d1e-aaaa "$HOLD" check mac-desktop --no-caller
  assert_failure 1
  run env CLAUDE_CODE_SESSION_ID=0d1e-aaaa "$HOLD" check mac-desktop
  assert_success
  run "$HOLD" check mac-desktop --as-me
  assert_failure 2
}

@test "a caller with TMUX but no TMUX_PANE has no tmux names: it never answers for the client's window" {
  tmux_stub
  in_pane dotfiles 3 4
  unset TMUX_PANE
  "$HOLD" set unity --by shepherd "hot"
  "$HOLD" grant unity hub/dotfiles:3
  as_session dotfiles-agent-18
  run "$HOLD" check unity
  assert_failure 1
  "$HOLD" claim mac-desktop "store form"
  grep -qx 'by: dotfiles-agent-18' "$AGENT_HOLD_DIR/mac-desktop"
}

@test "a claim made in a pane records its target and session id; the window keeps it after a renumber" {
  tmux_stub
  in_pane dotfiles 3 4
  CLAUDE_CODE_SESSION_ID=s-x "$HOLD" claim mac-desktop "store form"
  grep -qx 'by: hub/dotfiles:3' "$AGENT_HOLD_DIR/mac-desktop"
  grep -qx 'sid: s-x' "$AGENT_HOLD_DIR/mac-desktop"
  # another window of the same session is another caller
  in_pane dotfiles 2 4
  run env CLAUDE_CODE_SESSION_ID=s-y "$HOLD" check mac-desktop
  assert_failure 1
  run env CLAUDE_CODE_SESSION_ID=s-y "$HOLD" claim mac-desktop "screenshots"
  assert_failure 1
  # window 1 closed: the holder is now window 2, and its session id says it is still the holder
  run env CLAUDE_CODE_SESSION_ID=s-x "$HOLD" check mac-desktop
  assert_success
  run env CLAUDE_CODE_SESSION_ID=s-x "$HOLD" claim mac-desktop "store form, page 2"
  assert_output 'claimed: mac-desktop (refreshed)'
  grep -qx 'by: hub/dotfiles:2' "$AGENT_HOLD_DIR/mac-desktop"
  # a claim for a name given by --by is that name's, so it records no session id
  "$HOLD" release mac-desktop
  CLAUDE_CODE_SESSION_ID=s-x "$HOLD" claim mac-desktop --by agent-6 "for agent-6"
  run grep -c '^sid:' "$AGENT_HOLD_DIR/mac-desktop"
  assert_output 0
}

@test "claim: a second session is refused, the holder's check passes, release frees it" {
  run "$HOLD" claim mac-desktop --by agent-6 "store-console sign-in"
  assert_success
  assert_output 'claimed: mac-desktop'
  run "$HOLD" claim mac-desktop --by agent-9 "screenshots"
  assert_failure 1
  assert_output --partial 'busy: mac-desktop'
  assert_output --partial 'by agent-6 (other): store-console sign-in'
  run "$HOLD" check mac-desktop
  assert_failure 1
  run env TMUX= bash -c "cd \"\$(mktemp -d)\" && mkdir agent-6 && cd agent-6 && \"$HOLD\" check mac-desktop"
  assert_success
  run "$HOLD" claim mac-desktop --by agent-6 "store-console upload"
  assert_success
  assert_output 'claimed: mac-desktop (refreshed)'
  "$HOLD" release mac-desktop --by agent-6
  run "$HOLD" claim mac-desktop --by agent-9 "screenshots"
  assert_success
}

@test "release frees a claim only for its holder; --force frees one whose holder is gone (ar-751)" {
  "$HOLD" claim mac-desktop --by agent-42 "store form"
  # another session, by its own names or another --by, is refused and the claim stays
  run "$HOLD" release mac-desktop
  assert_failure 1
  assert_output --partial 'claimed by agent-42'
  run "$HOLD" release mac-desktop --by agent-9
  assert_failure 1
  grep -qx 'by: agent-42' "$AGENT_HOLD_DIR/mac-desktop"
  run "$HOLD" release mac-desktop --by
  assert_failure 2
  run "$HOLD" release mac-desktop --by ' '
  assert_failure 2
  # its holder releases it
  run "$HOLD" release mac-desktop --by agent-42
  assert_success
  [ ! -e "$AGENT_HOLD_DIR/mac-desktop" ]
  # a claim taken in a pane: another window is refused, and the holder's session id releases it
  # from wherever its window moved
  tmux_stub
  in_pane dotfiles 3 4
  CLAUDE_CODE_SESSION_ID=s-x "$HOLD" claim mac-desktop "screenshots"
  in_pane dotfiles 2 4
  run env CLAUDE_CODE_SESSION_ID=s-y "$HOLD" release mac-desktop
  assert_failure 1
  run env CLAUDE_CODE_SESSION_ID=s-x "$HOLD" release mac-desktop
  assert_success
  unset TMUX TMUX_PANE
  # a holder gone: --force frees it
  "$HOLD" claim mac-desktop --by agent-42 "store form"
  run "$HOLD" release mac-desktop --force
  assert_success
  [ ! -e "$AGENT_HOLD_DIR/mac-desktop" ]
  grep -F 'forced over agent-42' "$HOME/.agent/audit/actions.jsonl"
  # a claim past its until is over, so anyone releases it with no --force
  "$HOLD" claim mac-desktop --by agent-42 "store form"
  echo "until: $(date -d '-1 minute' +%Y-%m-%dT%H:%M:%S%z)" >> "$AGENT_HOLD_DIR/mac-desktop"
  run "$HOLD" release mac-desktop
  assert_success
  [ ! -e "$AGENT_HOLD_DIR/mac-desktop" ]
  # Negative control: a hold that is not a claim is still released by anyone.
  "$HOLD" set unity-tests --by d "96 C"
  run "$HOLD" release unity-tests
  assert_success
}

@test "claim --class records why the desktop is needed; busy names the holder's class and says when the caller outranks it" {
  run "$HOLD" classes
  assert_success
  [ "$(cut -f1 <<<"$output" | paste -sd' ')" = "auth legal release listing other" ]
  run "$HOLD" claim mac-desktop --by agent-6 --class nope "x"
  assert_failure 2
  assert_output --partial "unknown class 'nope'"
  [ ! -e "$AGENT_HOLD_DIR/mac-desktop" ]
  "$HOLD" claim mac-desktop --by agent-6 --class listing "screenshots"
  grep -qx 'class: listing' "$AGENT_HOLD_DIR/mac-desktop"
  run "$HOLD" list
  assert_output --partial $'agent-6\t[listing] screenshots'
  # A better class is told it goes next; it does not take the claim.
  run "$HOLD" claim mac-desktop --by agent-9 --class legal "xbox sign-up"
  assert_failure 1
  assert_output --partial 'by agent-6 (listing): screenshots (you outrank it'
  grep -qx 'by: agent-6' "$AGENT_HOLD_DIR/mac-desktop"
  # The same or a worse class hears only busy.
  run "$HOLD" claim mac-desktop --by agent-9 "explore"
  assert_failure 1
  refute_output --partial 'outrank'
  # A refresh with no --class keeps the class.
  "$HOLD" claim mac-desktop --by agent-6 "more screenshots"
  grep -qx 'class: listing' "$AGENT_HOLD_DIR/mac-desktop"
  # A class the table no longer has ranks last, with no shell error.
  sed -i 's/^class: .*/class: gone/' "$AGENT_HOLD_DIR/mac-desktop"
  run --separate-stderr "$HOLD" claim mac-desktop --by agent-9 --class auth "2fa"
  assert_failure 1
  [[ "$stderr" == *"(gone): more screenshots (you outrank it"* ]]
  [[ "$stderr" != *"integer"* ]]
  "$HOLD" release mac-desktop --by agent-6
  "$HOLD" claim mac-desktop --by agent-9 "explore"
  grep -qx 'class: other' "$AGENT_HOLD_DIR/mac-desktop"
  # A flag with no value is a usage error, not a hang.
  run timeout 5 "$HOLD" claim mac-desktop --class
  assert_failure 2
  run timeout 5 "$HOLD" claim mac-desktop --by
  assert_failure 2
}

@test "claim never replaces a set hold, and a set hold's owner is not let through by check" {
  "$HOLD" set unity-tests --by binks "hot"
  run "$HOLD" claim unity-tests --by agent-6 "mine"
  assert_failure 1
  # Past its until the hold is over: the claim releases it, then takes the resource.
  "$HOLD" set unity-tests --by binks --until '+1 hour' "hot"
  sed -i "s/^until: .*/until: $(date -d '-1 minute' +%Y-%m-%dT%H:%M:%S%z)/" "$AGENT_HOLD_DIR/unity-tests"
  run "$HOLD" claim unity-tests --by agent-6 "mine"
  assert_success
  assert_output 'claimed: unity-tests'
  run "$HOLD" show unity-tests
  assert_line 'kind: claim'
  assert_line 'by: agent-6'
  "$HOLD" release unity-tests
  "$HOLD" set unity-tests --by binks "hot"
  run env TMUX= bash -c "cd \"\$(mktemp -d)\" && mkdir binks && cd binks && \"$HOLD\" check unity-tests"
  assert_failure 1
}

# lower: a fake /proc with one cgroup file per pid; the sandbox's systemctl stub logs each
# call to calls.log.
lower_setup() {
  export AGENT_HOLD_PROC="$SANDBOX/proc"
  local u="/user.slice/user-$(id -u).slice/user@$(id -u).service"
  fake_pid 101 "$u/session.slice/tmux-spawn-aaa.scope"
  fake_pid 102 "$u/session.slice/tmux-spawn-aaa.scope"
  fake_pid 103 "$u/app.slice/agentctl@sentinel.service"
  fake_pid 104 "$u/session.slice/kitty-9327-0.scope"
  fake_pid 105 "/system.slice/docker.service"
  fake_pid 106 "$u/session.slice/tmux-spawn-bbb.scope/run-r1.scope"
  fake_pid self "$u/session.slice/tmux-spawn-me.scope"
  fake_pid 107 "$u/session.slice/tmux-spawn-me.scope"
}
fake_pid() { mkdir -p "$AGENT_HOLD_PROC/$1"; printf '0::%s\n' "$2" > "$AGENT_HOLD_PROC/$1/cgroup"; }
systemctl_calls() { grep '^systemctl ' "$NOTES_FIXTURE/calls.log" 2>/dev/null | sed 's/^systemctl //'; }

@test "lower sets CPUWeight=1 once per unit and records it on the hold" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests 101 102 103
  assert_success
  assert_line 'lowered: tmux-spawn-aaa.scope (pid 101)'
  assert_line 'lowered: tmux-spawn-aaa.scope (pid 102, already)'
  run systemctl_calls
  assert_output $'--user set-property --runtime tmux-spawn-aaa.scope CPUWeight=1\n--user set-property --runtime agentctl@sentinel.service CPUWeight=1'
  run "$HOLD" show unity-tests
  assert_line 'lowered: tmux-spawn-aaa.scope,agentctl@sentinel.service'
}

@test "lower leaves a desktop scope, a system unit, its own pane and a gone pid alone" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests 104 105 107 999 101
  assert_failure 1
  assert_output --partial 'kitty-9327-0.scope, not a tmux pane'
  assert_output --partial 'pid 105 is not under this user'
  assert_output --partial 'pid 107 is in this pane'
  assert_output --partial 'no process 999'
  run systemctl_calls
  assert_output '--user set-property --runtime tmux-spawn-aaa.scope CPUWeight=1'
}

@test "lower finds the pane scope around a nested scope" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests 106
  assert_success
  assert_line 'lowered: tmux-spawn-bbb.scope (pid 106)'
}

@test "a usage error outranks a refused pid in the exit code" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  run "$HOLD" lower unity-tests abc 999
  assert_failure 2
}

@test "lower refuses a claim, whose refresh would drop the record" {
  lower_setup
  "$HOLD" claim mac-desktop --by agent-6 "mine"
  run "$HOLD" lower mac-desktop 101
  assert_failure 2
  assert_output --partial 'is a claim'
}

@test "lower needs a hold to record on, so release can undo it" {
  lower_setup
  run "$HOLD" lower unity-tests 101
  assert_failure 1
  assert_output --partial 'is not held'
  run systemctl_calls
  assert_output ''
}

@test "a re-set keeps the lowered units, and release restores each one" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" lower unity-tests 101 103
  "$HOLD" set unity-tests --by c "hotter"
  run "$HOLD" show unity-tests
  assert_line 'lowered: tmux-spawn-aaa.scope,agentctl@sentinel.service'
  run "$HOLD" release unity-tests
  assert_success
  assert_line 'restored: tmux-spawn-aaa.scope'
  assert_line 'restored: agentctl@sentinel.service'
  run systemctl_calls
  assert_line -- '--user set-property --runtime tmux-spawn-aaa.scope CPUWeight='
  assert_line -- '--user set-property --runtime agentctl@sentinel.service CPUWeight='
}

@test "release skips a lowered unit whose pane is gone and frees the hold" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" lower unity-tests 101
  printf '#!/usr/bin/env bash\ncase "$*" in *LoadState*) echo not-found ;; *) exit 1 ;; esac\n' > "$SANDBOX/bin/systemctl"
  run "$HOLD" release unity-tests
  assert_success
  assert_line 'gone: tmux-spawn-aaa.scope'
  run "$HOLD" check unity-tests
  assert_success
}

@test "release keeps the hold and the record when a live unit cannot be restored" {
  lower_setup
  "$HOLD" set unity-tests --by c "hot"
  "$HOLD" lower unity-tests 101 103
  printf '#!/usr/bin/env bash\ncase "$*" in *LoadState*) echo loaded ;; *agentctl*) exit 0 ;; *) exit 1 ;; esac\n' > "$SANDBOX/bin/systemctl"
  run "$HOLD" release unity-tests
  assert_failure 1
  assert_line 'restored: agentctl@sentinel.service'
  assert_output --partial 'could not restore tmux-spawn-aaa.scope'
  run "$HOLD" show unity-tests
  assert_line 'lowered: tmux-spawn-aaa.scope'
}

@test "set, grant and release each write one audit line; a caller that records it writes none" {
  run "$HOLD" set unity-tests --by coordinator "96 C"
  assert_success
  run "$HOLD" grant unity-tests agent-2
  assert_success
  run "$HOLD" release unity-tests
  assert_success
  log="$HOME/.agent/audit/actions.jsonl"
  run jq -rc '[.actor, .action, .target, .outcome, .via, .to] | @tsv' "$log"
  assert_line --index 0 $'coordinator\thold.placed\tunity-tests\tok\tcli\t96 C'
  assert_line --index 1 --partial $'hold.granted\tunity-tests\tok\tcli\tagent-2'
  assert_line --index 2 --partial $'hold.released\tunity-tests\tok\tcli\twas: 96 C'
  # hub_core's System runner sets AGENT_AUDITED to its own pid, the tool's parent: here the
  # bash that starts it (the trailing exit keeps bash from exec-ing the tool in its place).
  run bash -c 'AGENT_AUDITED=$$ "$0" set unity-tests --by web x; exit $?' "$HOLD"
  assert_success
  run wc -l < "$log"
  assert_output 3
}

@test "release wakes a dispatch kick; set and a refused release do not (dispatch-event-wake)" {
  export FLEET_DISPATCH_DIR="$SANDBOX/dispatch"
  "$HOLD" set dispatch --by c "hot"
  [ ! -e "$FLEET_DISPATCH_DIR/.wake" ] || fail "a hold wrote a wake"
  run "$HOLD" release nothing-held
  assert_failure 1
  [ ! -e "$FLEET_DISPATCH_DIR/.wake" ] || fail "a release of nothing wrote a wake"
  "$HOLD" release dispatch
  [ -s "$FLEET_DISPATCH_DIR/.wake" ] || fail "a lifted hold wrote no wake"
  grep -q 'agent-hold release dispatch' "$FLEET_DISPATCH_DIR/.wake"
}

@test "release answers grant each open ask that asked only for a grant under that hold, as the human only from their own terminal (ar-6045)" {
  unset AGENT_ASK CLAUDE_CODE_SESSION_ID AGENT_QUEUE_ITEM
  d="$HOME/.agent/asks/demo"; mkdir -p "$d"
  ask() { printf 'id: %s\nproject: demo\nkind: question\nstatus: %s\ncreated: 2026-11-25T09:00:00-0800\nquestion: %s\noptions: %s\ncontext: %s\n' "$1" "$2" "$3" "$4" "${5:-}" > "$d/$1.md"; }
  ask g1 pending "May hc-1 run under the critical hold?" "grant|hold"
  ask g2 pending "May hc-2 merge now?" "Grant | keep" "the critical hold bars cluster work"
  # Negative controls: a third way, bare letters, another hold's name, a hold still set, answered.
  ask n1 pending "May hc-3 run under the critical hold?" "grant|hold|rewrite"
  ask n2 pending "May hc-4 run under the critical hold?" "a|b"
  ask n3 pending "May hc-5 run under the critical-dns hold?" "grant|hold"
  ask n4 pending "May hc-6 run under the critical and chores holds?" "grant|hold"
  ask n5 answered "May hc-7 run under the critical hold?" "grant|hold"
  printf 'answer: hold\nanswered_by: human\n' >> "$d/n5.md"
  "$HOLD" set critical --kind resource --by human --until '+12 hours' "lockdown"
  "$HOLD" set chores --kind resource --by coordinator "parked"
  # The human's own terminal: their answer.
  script -qec "$HOLD release critical" /dev/null > "$SANDBOX/release.out"
  grep -q 'released: critical' "$SANDBOX/release.out"
  grep -Eq 'answered grant \(human\): (g1 g2|g2 g1)' "$SANDBOX/release.out"
  for id in g1 g2; do
    grep -qx 'status: answered' "$d/$id.md"
    grep -qx 'answer: grant' "$d/$id.md"
    grep -qx 'answered_by: human' "$d/$id.md"
  done
  for id in n1 n2 n3 n4; do grep -qx 'status: pending' "$d/$id.md"; done
  grep -qx 'answer: hold' "$d/n5.md"
  # No terminal (a timer, fleet-dispatch) or an agent session: the agent's answer, and an ask only
  # the human answers is cancelled, since its hold is gone.
  ask g3 pending "May hc-8 run under the unity-tests hold?" "grant|hold"
  ask g4 pending "May hc-9 run under the unity-tests hold?" "grant|hold"
  echo 'judge_human_only: true' >> "$d/g4.md"
  "$HOLD" set unity-tests --by coordinator "hot"
  run "$HOLD" release unity-tests < /dev/null
  assert_success
  assert_line 'answered grant (agent): g3'
  assert_line 'cancelled (no hold left to grant under): g4'
  grep -qx 'answered_by: agent' "$d/g3.md"
  grep -qx 'status: cancelled' "$d/g4.md"
  ask g5 pending "May hc-10 run under the chores hold?" "grant|hold"
  run env CLAUDE_CODE_SESSION_ID=sid-1 "$HOLD" release chores
  # n4 named critical and chores; with both gone it is settled too.
  assert_line --regexp '^answered grant \(agent\): (g5 n4|n4 g5)$'
  # The claim path releases an expired hold and takes it at once: nothing is settled.
  ask g6 pending "May hc-11 use the mac-desktop hold?" "grant|hold"
  "$HOLD" set mac-desktop --kind resource --by coordinator --until '+1 hour' "busy"
  sed -i "s/^until: .*/until: $(date -d '-1 minute' +%Y-%m-%dT%H:%M:%S%z)/" "$AGENT_HOLD_DIR/mac-desktop"
  run "$HOLD" claim mac-desktop --by agent-6 "drive it"
  assert_success
  grep -qx 'status: pending' "$d/g6.md"
}
