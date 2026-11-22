# shellcheck shell=bash
# The fixtures and setup every tests/unit/fleet_dispatch*.bats file loads. Everything that could
# launch, claim or judge is a stub; calls.log records what it would do.

# fleet-dispatch: which rows may start an unattended session, and the bookkeeping around it.
# Everything that could launch, claim or judge is a stub; calls.log records what it would do.

# acct <name:reasons[:dir[:why]]>... -> claude-acct room --json answers these accounts, best rank
# first (main's dir is empty), with claude-acct's pick (the first with room) and its refusal
# sentence when there is none. reasons is ok, or every refusal joined by commas (pace, reserve,
# five_hour, committed, capped, unread); why is the first refusal's words, a stock sentence when not
# given. Each ask is counted in room.n, and acct.<n>.json, when present, answers ask n (from 0).
# Its `sources` are the rows srcs wrote, none by default. Every other verb exits 0.
acct() {
  local spec name reasons dir why rank=0 rows='[]'
  for spec in "$@"; do
    IFS=: read -r name reasons dir why <<<"$spec"
    rank=$((rank + 1))
    rows=$(jq -c --arg n "$name" --arg r "$reasons" --arg d "$dir" --arg w "$why" --argjson k "$rank" '
      ($r | split(",") | map(select(. != "ok"))) as $no
      | {pace: "1 point over its weekly pace", reserve: "90% of its week used, inside the last 15% kept for the human",
         five_hour: "its 5h window at 90%", committed: "its 2 working sessions use the rest of its week before the reset",
         capped: "out of its week", unread: "its usage cannot be read"} as $stock
      | . + [{name: $n, dir: $d, state: (if $no == ["unread"] then "unread" else "ok" end), rank: $k,
              room: {ok: ($no == []), reason: ($no[0] // "ok"), reasons: $no, capped: ($no | index("capped") != null),
                     why: (if $no == [] then "it has room" elif $w != "" then $w else $stock[$no[0]] end)}}]' <<<"$rows")
  done
  jq -c '([.[] | select(.room.ok)] | first | .name) as $p
    | ([.[] | select(.state != "unread")] | first) as $c
    | {pick: $p, accounts: .,
       why: (if $p then null elif any(.[]; .state == "unread") then "no account has room and one cannot be read"
             elif $c == null then "no account has room under its weekly pace and after its live sessions"
             else "no account has room; \($c.name) is the closest, \($c.room.why)" end)}' <<<"$rows" > "$NOTES_FIXTURE/acct.json"
  rm -f "$NOTES_FIXTURE/room.n"
  stub claude-acct 'if [ "$1 ${2:-}" = "room --source" ]; then
  echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"
  # --json: the row, its why the src.<name> text past "<name>: ", and live.<name> (a JSON object) merged in.
  if [ "${4:-}" = --json ]; then
    w=$(cat "$NOTES_FIXTURE/src.$3" 2>/dev/null) && ok=false || ok=true
    jq -nc --arg n "$3" --arg w "${w#"$3: "}" --argjson ok "$ok" --argjson x "$(cat "$NOTES_FIXTURE/live.$3" 2>/dev/null || echo {})" \
      '"'"'{name: $n, live: 0, max_live: 2, room: {ok: $ok, why: (if $ok then "it has room" else $w end)}} + $x'"'"'
    [ "$ok" = true ]; exit
  fi
  [ -e "$NOTES_FIXTURE/src.$3" ] && { cat "$NOTES_FIXTURE/src.$3"; exit 1; }
  # --model <route>: route_spent refused that route alone, whatever the source row says.
  if [ "${4:-}" = --model ]; then r=$(printf %s "${5:-}" | tr -c "A-Za-z0-9._-" _)
    [ -e "$NOTES_FIXTURE/route.$r" ] && { cat "$NOTES_FIXTURE/route.$r"; exit 1; }; fi
  echo "$3: room"; exit 0
fi
[ "$1 ${2:-}" = "room --json" ] || exit 0
n=$(cat "$NOTES_FIXTURE/room.n" 2>/dev/null || echo 0); echo $((n + 1)) > "$NOTES_FIXTURE/room.n"
f="$NOTES_FIXTURE/acct.json"; [ ! -e "$NOTES_FIXTURE/acct.$n.json" ] || f="$NOTES_FIXTURE/acct.$n.json"
jq -c --slurpfile s <(cat "$NOTES_FIXTURE/sources.json" 2>/dev/null || echo "[]") ".sources = \$s[0]" "$f"
# room.rc: the exit the real one gives with its answer whole (1: no account to pick).
[ ! -e "$NOTES_FIXTURE/room.rc" ] || exit "$(cat "$NOTES_FIXTURE/room.rc")"'
}

# srcs <name:reasons:rank>... -> the sources claude-acct room --json lists beside the accounts:
# reasons is ok or a refusal (reserve, max_live, parent), rank the source's (lower is used first). A
# refused one also refuses `room --source`, so a launch past routing reads the same verdict.
srcs() {
  local spec name reasons rank rows='[]'
  for spec in "$@"; do
    IFS=: read -r name reasons rank <<<"$spec"
    rows=$(jq -c --arg n "$name" --arg r "$reasons" --argjson k "$rank" '. + [{name: $n, kind: "x", state: "ok", rank: $k, live: 0,
      room: {ok: ($r == "ok"), reason: $r, reasons: (if $r == "ok" then [] else [$r] end),
             why: (if $r == "ok" then "it has room" else "inside its \($r)" end)}}]' <<<"$rows")
    rm -f "$NOTES_FIXTURE/src.$name"
    [ "$reasons" = ok ] || echo "$name: inside its $reasons" > "$NOTES_FIXTURE/src.$name"
  done
  printf '%s\n' "$rows" > "$NOTES_FIXTURE/sources.json"
}

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export FLEET_DISPATCH_DIR="$HOME/.agent/dispatch"
  sandbox_worlds
  export DISPATCH_PROFILES=bnb
  # The tuning these cases are written against: the code defaults of the keys the agentctl conf sets
  # hold every start ("a key the conf sets gets a neutral default"), and the sandbox has no conf.
  export DISPATCH_TARGET_PRESENT=50 DISPATCH_TARGET_AWAY=25 DISPATCH_MAX_LOAD=0.7 DISPATCH_LOW_WATER=3
  export DISPATCH_PROJECT_MAP="$SANDBOX/map.json"
  export DISPATCH_POLICY="$SANDBOX/policy.md"
  export DISPATCH_WORKERS="$SANDBOX/workers.json"
  export DISPATCH_KINDS="$REPO_ROOT/.config/fleet-dispatch/kinds.json"
  echo '{"fleet": {"max_tier": 1}}' > "$DISPATCH_WORKERS"
  export DISPATCH_LOADAVG="$SANDBOX/loadavg"
  export DISPATCH_JUDGE_CMD=judge-stub   # on PATH: the command is a word list, and the sandbox path has a space
  echo '0.10 0.10 0.10 1/1 1' > "$DISPATCH_LOADAVG"
  export DISPATCH_CANARY_KEEP=0   # off unless a test is about it ("canary top-up:"), so no pass asks fleet-bench for canaries
  export DISPATCH_FLEET_SHARE=0   # off unless a test is about it ("fleet share:"), so a fleet project's item starts in queue order
  export DISPATCH_START_LOAD=0   # a start adds no pending load unless a test is about it, whatever the runner's cores
  export DISPATCH_PER_PASS=1   # one start a pass unless a test is about it; the shipped default, 0, is no cap
  printf '%s\n' 'policy' '- (fits) dispatch' '- (unclear) not clear' > "$DISPATCH_POLICY"
  mkdir -p "$SANDBOX/repos/game" "$SANDBOX/repos/app" "$SANDBOX/sheets"
  : > "$NOTES_FIXTURE/tmux.sessions.lab"
  stub_notes
  stub agent-hold 'exit 0'
  stub store-sync 'exit 0'   # reap reads a peer host's items from origin (store_fresh); this one is current
  stub store-sync-age 'exit 0'
  stub fleet-assess '[ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  stub fleet-presence 'echo "away 45 tmux"'
  # A fresh fleet state document with no session in it: the pace target counts none unless a test adds them.
  export FLEET_STATE_FILE="$SANDBOX/state.json"
  fleet_state 0
  stub fleet-bench 'exit 0'
  stub fleet-shepherd 'exit 1'
  acct main:ok   # main account with room; a test that wants the alt one restubs it
  stub model-lane 'echo "{\"dispatch_model\":\"opus\"}"'
  stub wt 'echo "wt $*" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  stub judge-stub 'echo "judge called" >> "$NOTES_FIXTURE/calls.log"; cat "$NOTES_FIXTURE/judge.out" 2>/dev/null'
  # The real agent-queue, copied (never linked: a test that restubs it must not write through).
  cp "$REPO_ROOT/.local/bin/agent-queue" "$SANDBOX/bin/agent-queue"
  # The ladder `notes projects --stages` prints; the stub answers projects lists only.
  export LAB_STAGES="draft dev alpha beta prod"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"
  export AGENT_QUEUE_DIR="$HOME/.agent/queue" AGENT_QUEUE_PROJECT_MAP="$DISPATCH_PROJECT_MAP" AGENT_QUEUE_START=0
  # Fixtures seed the queue as dispatch's pull would; a test of the board-only rule unsets it.
  export AGENT_QUEUE_PULL=dispatch
  # The launch env as stow deploys it, off the LAN (getent fails), so a start reads its defaults
  # (dropped_tools) and adds no telemetry unless a test stubs getent to say it is on the LAN.
  mkdir -p "$HOME/.config/shared-hooks"
  cp "$REPO_ROOT/.config/shared-hooks/claude-telemetry.sh" "$HOME/.config/shared-hooks/"
  stub getent 'exit 2'
  unset CLAUDE_AUTO_DROP_TOOLS
  # The prefix every launch line starts with (claude_launch_env, tested in claude_telemetry.bats).
  LAUNCH_ENV=$(bash -c '. "$HOME/.config/shared-hooks/claude-telemetry.sh" && claude_launch_env' 2>/dev/null)
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-dispatch"
}

# class_floors <requested min_live> <cleanup min_live> -> a classes.json mix with those minimums: the board
# top-up above the low water reads them (class_gap). A case that never calls it has no mix, so no floor.
class_floors() {
  export AGENT_QUEUE_CLASSES="$SANDBOX/classes.json"
  jq -n --argjson r "$1" --argjson c "$2" '{on: true, window_days: 7, classes: [
    {name: "requested", share: 60, tags: ["requested"], min_live: $r},
    {name: "cleanup", share: 10, tags: ["cleanup"], min_live: $c},
    {name: "rest", share: 30, default: true}]}' > "$AGENT_QUEUE_CLASSES"
}

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/bin/$1"; chmod +x "$SANDBOX/bin/$1"; }
# mask_sid <log>... -> each launch's random `--session-id <uuid>` becomes `--session-id SID`, so a test
# can assert the whole command line.
mask_sid() { sed -i -E 's/--session-id [0-9a-f-]{36}/--session-id SID/g' "$@"; }

# started_item <slug> <session> [origin] [area] [from] [state] [project] -- a started queue item on
# that session (<server>:<name>): the one record of a running session.
started_item() {
  local d="$AGENT_QUEUE_DIR/${6:-running}"; mkdir -p "$d"
  {
    printf 'slug: %s\nproject: %s\nmode: oneshot\npriority: high\nfrom: %s\nagent: claude\nqueued: 2026-11-03T10:00:00Z\n' "$1" "${7:-game}" "${5:-human}"
    printf 'started: 2026-11-03T10:00:00Z\nsession: %s\n' "$2"
    [ -z "${3:-}" ] || printf 'origin: %s\n' "$3"
    [ -z "${4:-}" ] || printf 'area: %s\n' "$4"
    [[ "${5:-}" != board:* ]] || printf 'lane: human\nprofile: bnb\n'
    printf -- '---\n%s\n' "$1"
  } > "$d/20261103-100000-$1.md"
}

# A notes stand-in with state: rows.<project>.<lane> holds "key<TAB>raw line". `start` sets one
# row to [/] and `unstart` back to [ ], as the real CLI does, and a row already there is left
# unchanged: the row whose line is the query under --exact, else the one with that id, else the
# first whose key contains it. A row going to [/] with no id gets the next gm-N and the id goes
# out on its own line, unless the fixture says the project has no code (nocode.<project>).
# `board --json` lists each row with its #tags, an [x] one under `done` as the real board does;
# `tag (--add|--remove <tag>)... <id>` edits the row's tags.
stub_notes() {
  cat > "$SANDBOX/bin/notes" <<'EOF'
#!/usr/bin/env bash
F="$NOTES_FIXTURE"; printf 'notes %s\n' "$*" >> "$F/calls.log"
args=(); lane=human; exact=0
while [ $# -gt 0 ]; do
  case "$1" in --profile) shift 2 ;; --agent) lane=agent; shift ;; --exact) exact=1; shift ;; --) shift ;; *) args+=("$1"); shift ;; esac
done
case "${args[0]}" in
  projects) if [[ " ${args[*]} " == *" --prios "* ]]; then cat "$F/prios" 2>/dev/null; else cat "$F/projects" 2>/dev/null; fi ;;
  row)   # `row parse`: a stand-in for the grammar's home (notes-cli), enough for these fixtures: type(area): with a type in kinds.json
    while IFS= read -r l; do
      t=$(sed -nE 's/^(- \[.\] )?([a-z]+)\([a-z0-9-]+\):.*/\2/p' <<<"$l")
      if [ -n "$t" ] && jq -e --arg t "$t" 'has($t)' "$DISPATCH_KINDS" >/dev/null 2>&1; then printf '%s\t-\t%s\t1\n' "$t" "$l"
      else printf -- '-\t-\t%s\t0\n' "$l"; fi
    done ;;
  board)
    # A fixture with board.sprints (one JSON array of the feed's `sprints`) adds them to the feed; without one it is [], as the real feed always carries it.
    { if [ -f "$F/board.rows" ]; then jq -sc '{rows: ., done: []}' "$F/board.rows"
    else
      for f in "$F"/rows.*.*; do
        [ -f "$f" ] || continue
        p=${f#"$F/rows."}; lane=${p##*.}; p=${p%.*}
        jq -Rn --arg p "$p" --arg l "$lane" '
          inputs | split("\t") | {profile: "bnb", project: $p, lane: $l, id: ((.[1] | capture("<!-- id:(?<i>[^ ]+)") | .i) // .[0]), raw: .[1],
            # As notes gives them: tags lower-cased for grouping, tags_cased as written (a gate value is data).
            tags_cased: [.[1] | split("<!--")[0] | scan("(?:^|\\s)#([A-Za-z0-9_./-]+)") | .[0]],
            tags: [.[1] | split("<!--")[0] | scan("(?:^|\\s)#([A-Za-z0-9_./-]+)") | .[0] | ascii_downcase],
            since: ((.[1] | capture("since:(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})") | .d) // null),
            marker: ((.[1] | capture("<!--.* (?<m>dropped)") | .m) // ""),
            state: (if (.[1] | startswith("- [/]")) then "doing" elif (.[1] | startswith("- [x]")) then "done" else "open" end)}' < "$f"
      done | jq -sc '{rows: map(select(.state != "done")), done: map(select(.state == "done"))}'
    fi; } | if [ -f "$F/board.sprints" ]; then jq -c --slurpfile s "$F/board.sprints" '. + {sprints: $s[0]}'; else jq -c '. + {sprints: (.sprints // [])}'; fi ;;
  ptask)
    p="${args[1]}"; f="$F/rows.$p.$lane"
    [ "${args[2]}" != add ] || [ ! -f "$F/refuse.$p" ] || exit 1   # a sheet that refuses the row: touch $F/refuse.<project>
    [ -f "$f" ] || exit 0
    case "${args[2]}" in
      list) awk -F'\t' -v f="$f" '$2 ~ /^- \[[ \/]\]/ { print f "\t" NR "\t" $1 "\t" $2 }' "$f" ;;
      start|unstart)
        n=$(cat "$F"/rows.*.* | grep -c 'id:gm-'); [ ! -f "$F/nocode.$p" ] || n=''
        Q="${args[3]}" awk -F'\t' -v OFS='\t' -v exact="$exact" -v n="$n" -v out="$f.out" -v verb="${args[2]}" '
          BEGIN { q = ENVIRON["Q"] }
          !done && $2 ~ /^- \[[ \/]\]/ && (exact ? $2 == q : (index($2, "id:" q " ") || index($1, q))) {
            done = 1
            if (verb == "unstart") {
              if (sub(/^- \[\/\]/, "- [ ]", $2)) print "unstarted " $2 > out; else print "unchanged " $2 > out
            } else if ($2 ~ /^- \[\/\]/) print "unchanged " $2 > out
            else {
              sub(/^- \[ \]/, "- [/]", $2); print "started " $2 > out
              if (n != "" && $2 !~ /id:/) { id = "gm-" (n + 1); $2 = $2 " <!-- id:" id " -->"; print "  id:" id > out }
            }
          }
          { print }' "$f" > "$f.new" && mv "$f.new" "$f"
        [ -f "$f.out" ] || { echo "no open task matches" >&2; exit 1; }
        cat "$f.out"; rm -f "$f.out" ;;
      done)   # closed rows leave `list`, as the real board's do
        Q="${args[3]}" awk -F'\t' -v OFS='\t' '
          !hit && $2 ~ /^- \[[ \/]\]/ && (index($2, "id:" ENVIRON["Q"] " ") || index($1, ENVIRON["Q"])) { hit = 1; sub(/^- \[[ \/]\]/, "- [x]", $2) }
          { print }' "$f" > "$f.new" && mv "$f.new" "$f" ;;
      drop)   # drop <id> --why <why>: ticked, the why in its marker, as the real CLI keeps it
        Q="${args[3]}" W="${args[5]:-}" awk -F'\t' -v OFS='\t' '
          !hit && $2 ~ /^- \[[ \/]\]/ && index($2, "id:" ENVIRON["Q"] " ") { hit = 1; sub(/^- \[[ \/]\]/, "- [x]", $2); sub(/ -->/, " dropped: " ENVIRON["W"] " -->", $2) }
          { print }' "$f" > "$f.new" && mv "$f.new" "$f" ;;
      tag)   # tag (--add|--remove <tag>)... <id>: an added tag goes in ahead of the row's marker
        for ((k = 3; k + 1 < ${#args[@]}; k += 2)); do
          Q="${args[-1]}" OP="${args[k]}" T="${args[k + 1]}" awk -F'\t' -v OFS='\t' '
            !done && index($2, "id:" ENVIRON["Q"] " ") { done = 1
              if (ENVIRON["OP"] == "--add") sub(/ <!--/, " #" ENVIRON["T"] " <!--", $2)
              else if (i = index($2, " #" ENVIRON["T"] " ")) $2 = substr($2, 1, i - 1) substr($2, i + length(ENVIRON["T"]) + 2) }
            { print }' "$f" > "$f.new" && mv "$f.new" "$f"
        done ;;
    esac ;;
esac
EOF
  chmod +x "$SANDBOX/bin/notes"
}

# project <name> <stage> <repo-dir|-> : a project dir, a registry entry, and a projects line. The
# stage sits on README.md while the listing names summary.md, the shape `notes projects` prints for
# a profile whose index links the summary (bnb): the reader must find the front page itself.
project() {
  mkdir -p "$SANDBOX/sheets/$1"
  printf 'Version: v1.0.0 #%s\n' "$2" > "$SANDBOX/sheets/$1/README.md"
  printf '# %s\n' "$1" > "$SANDBOX/sheets/$1/summary.md"
  printf '%s\t%s\t\tv1.0.0\n' "$1" "$SANDBOX/sheets/$1/summary.md" >> "$NOTES_FIXTURE/projects"
  local m='{"trackers":{},"paths":{}}'; [ -f "$DISPATCH_PROJECT_MAP" ] && m=$(cat "$DISPATCH_PROJECT_MAP")
  if [ "$3" = - ]; then
    jq --arg p "$1" '.trackers[$p] = {repo: null}' <<<"$m" > "$DISPATCH_PROJECT_MAP"
  else
    jq --arg p "$1" --arg d "$3" '.trackers[$p] = {repo: $p} | .paths[$d] = $p' <<<"$m" > "$DISPATCH_PROJECT_MAP"
  fi
}

row() { printf '%s\t%s\n' "$3" "$4" >> "$NOTES_FIXTURE/rows.$1.$2"; }

# trainee_repo <dir> -- a git repo a trainee may see (DISPATCH_TRAINEE_REPOS) with a sensitive-tokens
# list (`secretword`), as trainee_public_why reads it.
trainee_repo() {
  [ -d "$1/.git" ] || git init -q "$1"
  mkdir -p "$1/.githooks"
  printf '# tokens\n\nsecretword\n' > "$1/.githooks/sensitive-tokens.txt"
  export DISPATCH_TRAINEE_REPOS="$1"
}

# board_row <project> <lane> <id> <tags json> <details json> [rank] -- that fixture row as `notes board
# --json` gives it (its raw line from rows.<project>.<lane>), with tags, details and its feed rank (null by default)
board_row() {
  jq -cn --arg p "$1" --arg l "$2" --arg i "$3" --argjson t "$4" --argjson d "$5" --argjson r "${6:-null}" \
    --arg raw "$(awk -F'\t' -v k="$3" '$1 == k { print $2; exit }' "$NOTES_FIXTURE/rows.$1.$2")" \
    '{profile: "bnb", project: $p, lane: $l, id: $i, state: "open", tags: $t, details: $d, raw: $raw, text: $raw, rank: $r}' \
    >> "$NOTES_FIXTURE/board.rows"
}

# fk <due 0-3> <prio 0 urgent|1 high|2 low> <req 0|1> [created YYYY-MM-DD] -> the feed `rank` notes-cli
# prints for such a row (src/rank.rs Rank::key), so a fixture states what the board would say
fk() {
  local day=0
  [ -z "${4:-}" ] || day=$(( $(date -ud "$4" +%s) / 86400 ))
  echo $(( (($1 * 3 + $2) * 2 + $3) * 1000000 + day ))
}

# ranked <project> <lane> <id> <rank> -- the feed row of a fixture row, with that rank
ranked() { board_row "$1" "$2" "$3" '[]' '[]' "$4"; }

# A tagged row the fleet worker may take.
T='#worker/fleet #tier/1'

# line_of <project> <lane> <key> -> the line signature of that fixture row, as candidates computes it
# (nothing when there is no such row, as for the synthetic candidates the picks tests build).
line_of() {
  local text
  text=$(awk -F'\t' -v k="$3" '$1 == k { print $2; exit }' "$NOTES_FIXTURE/rows.$1.$2" 2>/dev/null)
  [ -z "$text" ] || row_sig "$text"
}

# verdict <project> <lane> <key> <verdict> [size] [tier] [area] -- made under the current policy for the row's current text
verdict() {
  mkdir -p "$FLEET_DISPATCH_DIR"
  jq -cn --arg p "$1" --arg l "$2" --arg k "$3" --arg v "$4" --arg s "${5:-S}" --argjson t "${6:-1}" \
    --arg sig "$(policy_sig)" --arg line "$(line_of "$1" "$2" "$3")" --arg a "${7-$3}" \
    '{project: $p, lane: $l, key: $k, verdict: $v, size: $s, tier: $t, area: $a, clear: true, agent_only: true,
      rule: "fits", reason: "r", policy: $sig, line: $line}' >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
}

# plan_fixture -- agent rows skipped by each kind of rule, one already planned, one edited since,
# a human row, and one row already waiting on its plan
plan_fixture() {
  printf '%s\n' '- (design) needs a product call' '- (bundle) several tasks' >> "$DISPATCH_POLICY"
  project game beta "$SANDBOX/repos/game"
  local k
  for k in ga-1 ga-2 ga-3 ga-4 ga-5 ga-7; do row game agent "$k" "- [ ] row $k $T <!-- id:$k -->"; done
  row game agent ga-6 "- [ ] row ga-6 #plan $T <!-- id:ga-6 -->"
  row game human gh-1 "- [ ] row gh-1 $T <!-- id:gh-1 -->"
  for k in ga-1 ga-2 ga-4 ga-5 ga-7; do board_row game agent "$k" '[]' '[]'; done
  board_row game agent ga-3 '[]' '["goal: already planned"]'
  board_row game agent ga-6 '["plan"]' '[]'
  board_row game human gh-1 '[]' '[]'
  rule() { verdict game "$1" "$2" skip; jq -c --arg r "$3" 'if .key == "'"$2"'" then .rule = $r else . end' \
    "$FLEET_DISPATCH_DIR/verdicts.jsonl" > "$SANDBOX/v" && mv "$SANDBOX/v" "$FLEET_DISPATCH_DIR/verdicts.jsonl"; }
  rule agent ga-1 unclear; rule agent ga-2 design; rule agent ga-3 unclear; rule agent ga-5 unclear
  rule agent ga-7 bundle; rule human gh-1 unclear
  verdict game agent ga-4 dispatch
  # ga-5 was edited after its verdict
  sed -i 's/row ga-5/row ga-5 now longer/' "$NOTES_FIXTURE/rows.game.agent"
  : > "$NOTES_FIXTURE/board.rows"
  for k in ga-1 ga-2 ga-4 ga-5 ga-7; do board_row game agent "$k" '[]' '[]'; done
  board_row game agent ga-3 '[]' '["goal: already planned"]'
  board_row game agent ga-6 '["plan"]' '[]'
  board_row game human gh-1 '[]' '[]'
  stub systemctl 'echo "$*" >> "$NOTES_FIXTURE/systemctl.log"'
}

board_workers() {
  echo '{"requested": {"max_tier": 2, "only_tag": "requested"},
         "fleet": {"max_tier": 1},
         "board": {"max_tier": 2, "lane": "agent", "untagged": true}}' > "$DISPATCH_WORKERS"
}

# c_area <key> <feed rank>: a candidate on project game
c_area() { jq -cn --arg k "$1" --argjson fr "$2" '{profile: "bnb", project: "game", stage: "beta", lane: "agent", key: $k, frank: $fr, tier: 2, line: ""}'; }

# kinds_match <kinds.json> -- its keys are notes-cli's ROW_TYPES, no more and no fewer, and every
# entry carries the fields dispatch and shepherd read
kinds_match() {
  local types keys
  types=$(sed -n '/const ROW_TYPES/,/];/p' "$REPO_ROOT/.local/src/notes-cli/src/projects.rs" | grep -oE '"[a-z]+"' | tr -d '"' | sort)
  [ -n "$types" ] || { echo "no ROW_TYPES read from projects.rs"; return 1; }
  keys=$(jq -r 'keys[]' "$1" | sort)
  [ "$types" = "$keys" ] || { echo "kinds.json keys differ from ROW_TYPES:"; diff <(echo "$types") <(echo "$keys"); return 1; }
  jq -e 'to_entries | all(.value | (.rank | type) == "number" and (.entry | type) == "string"
    and (.rung | IN("build", "propose", "human")) and (.exit | type) == "string"
    and (.enabled | type) == "boolean")' "$1" >/dev/null || { echo "an entry lacks a field"; return 1; }
  # The project's stage decides where a row dispatches (dispatchable), so no kind repeats it.
  jq -e 'to_entries | all(.value | has("stages") or has("off") | not)' "$1" >/dev/null || { echo "an entry has stages or off: the stage is dispatchable's"; return 1; }
}

# --- run ---------------------------------------------------------------------------------

game_ready() {
  project game beta "$SANDBOX/repos/game"
  row game human 'fix crash on load' "- [ ] fix crash on load #high $T"
  verdict game human 'fix crash on load' dispatch
}

# refuses <text>: this pass stopped at a gate and said so, with everything else passing.
refuses() {
  run "$REPO_ROOT/.local/bin/fleet-dispatch" run
  assert_success
  assert_output --partial "$1"
  assert_not_called 'wt new'
  assert_not_called 'judge called'
}

# room_on_floor: the one account's verdict refuses it for its pace alone, so it has room only while
# a floor lifts the pace reason.
room_on_floor() {
  acct alt:pace:/home/u/.claude-personal
}

# 2026-11-06: reds sat queued behind a machine held by Unity CI (load 1.4x, 96.5 C), which the run
# floor does not lift. The human chose a floor of red starts of its own.
red_held_machine() {
  project game beta "$SANDBOX/repos/game"
  room_on_floor
  stub fleet-assess '[ "$1" = --watch-probe ] && exit 1; [ "$1" = --github ] && echo "github: 4000/5000 REST calls left, resets 13:00"; exit 0'
  echo "$(( $(nproc) * 2 )).00 1 1 1/1 1" > "$DISPATCH_LOADAVG"
  export DISPATCH_RUN_FLOOR=0 DISPATCH_PER_PASS=3 DISPATCH_RED_FLOOR=2
}

# finding <rule> <scope> [repos json] -- one finding row fleet-bench reports as firing now
finding() { jq -cn --arg r "$1" --arg s "$2" --argjson repos "${3:-null}" --arg b "${4:-}" --argjson e "$(date +%s)" '{rule: $r, scope: $s, repos: $repos, epoch: $e} + (if $b == "" then {} else {bind: $b} end)'; }
# findings <row>... -- fleet-bench reports exactly those rows
findings() { printf '%s\n' "$@" > "$SANDBOX/findings.out"; stub fleet-bench "cat '$SANDBOX/findings.out'"; }

# two_items: a game item at the head of the queue and an app item behind it, both the human's
two_items() {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  agent-queue add --project game --slug fix-game --priority high "fix the game"
  agent-queue add --project app --slug fix-app --priority low "fix the app"
}

# held_game_app_row: a game queue item a starved unity pool holds, and an app board row it does not
held_game_app_row() {
  project game beta "$SANDBOX/repos/game"
  project app beta "$SANDBOX/repos/app"
  agent-queue add --project game --slug fix-game --priority high "fix the game"
  row app human 'fix app crash' "- [ ] fix app crash #high $T"
  verdict app human 'fix app crash' dispatch
  findings "$(finding starved pool:unity '["game"]')"
}

# fleet_state <live sessions> [<age in minutes>] -- the fleet state document fleet-sessions writes,
# holding that many live sessions, written that long ago. On top sit a parked, a finished, the
# shepherd's session and a codex and an opencode run, which the pace target never counts.
fleet_state() {
  jq -cn --argjson n "$1" --argjson at "$(( $(date +%s) - ${2:-0} * 60 ))" \
    '{generated_epoch: $at, vocab: {finished: ["DONE", "LANDED"]},
      sessions: ([range($n) | {target: "hub/s:\(.)", bucket: "WORKING"}]
        + [{target: "lab/p", bucket: "PARKED"}, {target: "lab/d", bucket: "DONE"}, {target: "hub/sh", bucket: "WORKING", labels: ["shepherd"]},
           {target: "lab/cx", bucket: "WORKING", account: "codex"}, {target: "razer-laptop@lab/oc", bucket: "WORKING", account: "opencode"}])}' > "$FLEET_STATE_FILE"
}

# line_state <working> <waiting> <project>: fleet_state's <working> sessions plus <waiting> of <project> whose
# background shell is a gate waiting its landing turn (open_job queue, fleet-sessions live_wait).
line_state() {
  fleet_state "$1"
  jq -c --argjson q "$2" --arg p "$3" '.sessions += [range($q) | {target: "lab/q:\(.)", bucket: "WORKING", project: $p, open_job: "queue"}]' \
    "$FLEET_STATE_FILE" > "$FLEET_STATE_FILE.tmp" && mv "$FLEET_STATE_FILE.tmp" "$FLEET_STATE_FILE"
}

# outcome: what the pass told fleet-liveness, through the real agent-proof.sh the sandbox links.
# agentctl calls a run that says nothing STALLED.
outcome() { cat "$HOME/.local/state/agentctl/fleet-dispatch/last-outcome" 2>/dev/null; }

# 5 of 6 run units held by two heavy and one light live session, as the tests around it do.
five_of_six_units() {
  project game beta "$SANDBOX/repos/game"
  export DISPATCH_TARGET_AWAY=6
  local s
  for s in h1 h2 l1; do started_item "$s" "lab:game-agent-$s" run "area-$s"; done
  sed -i '/^mode:/a weight: heavy' "$AGENT_QUEUE_DIR"/running/*-h1.md "$AGENT_QUEUE_DIR"/running/*-h2.md
  printf 'game-agent-h1\ngame-agent-h2\ngame-agent-l1\n' > "$NOTES_FIXTURE/tmux.sessions.lab"
}

# --- preempt: an urgent item takes a runner session's unit (plan urgent-runs-now P2) -----------

# park_stub -- claude-acct park and unpark log to calls.log; park writes the ledger claude-acct would
# (session, server, why, for), unpark removes it, and park.refuse makes park refuse as a busy session.
# Every other verb goes to the acct stub.
park_stub() {
  mv "$SANDBOX/bin/claude-acct" "$SANDBOX/bin/claude-acct-room"
  stub claude-acct 'P="${CLAUDE_ACCT_PARKED_DIR:-$HOME/.agent/parked}"
case "$1" in
  park) echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"
        [ ! -e "$NOTES_FIXTURE/park.refuse" ] || { echo "claude-acct: park ${2#*/}: busy mid-turn; park it once the turn ends" >&2; exit 1; }
        mkdir -p "$P"; printf "session=%s\nserver=%s\nwhy=%s\nfor=%s\nparked=%s\n" "${2#*/}" "${2%%/*}" "$4" "$6" "$(date +%s)" > "$P/${2#*/}" ;;
  unpark) echo "claude-acct $*" >> "$NOTES_FIXTURE/calls.log"; rm -f "$P/$2" ;;
  *) exec claude-acct-room "$@" ;;
esac'
}

# six_of_six_units -- five_of_six_units plus a low light runner session, l2: every unit is held.
six_of_six_units() {
  five_of_six_units
  started_item l2 lab:game-agent-l2 run area-l2
  sed -i 's/^priority: high/priority: low/' "$AGENT_QUEUE_DIR"/running/*-l2.md
  echo game-agent-l2 >> "$NOTES_FIXTURE/tmux.sessions.lab"
  park_stub
}

# ledger <session> <why> -- a park ledger as claude-acct writes it, parked at epoch 1.
ledger() {
  mkdir -p "$HOME/.agent/parked"
  printf 'session=%s\nserver=lab\nwhy=%s\nparked=1\n' "$1" "$2" > "$HOME/.agent/parked/$1"
}

# --- reap --------------------------------------------------------------------------------

# approved_plan <name> <session> [phases] -- a plan file and its ledger line, as plan-approved.sh writes it.
approved_plan() {
  export PLAN_LEDGER="$SANDBOX/approved.jsonl"
  printf '# Plan\n\n## Phases\n\n%b\n' "${3:-- [x] one\n- [ ] two\n- [ ] three}" > "$SANDBOX/$1.md"
  jq -nc --arg p "$SANDBOX/$1.md" --arg s "$2" --argjson e "$(date +%s)" \
    '{epoch: $e, plan: $p, project: "game", session: $s, cwd: "/x"}' >> "$PLAN_LEDGER"
}

# codex_run <slug>... -- each a live `agent-codex run` process with AGENT_QUEUE_ITEM=<slug>, as pgrep and
# /proc show it to codex_run_live.
codex_run() {
  local slug pid=4000 pids=''
  export DISPATCH_PROC="$SANDBOX/proc"
  for slug in "$@"; do
    pid=$((pid + 1)); pids="$pids $pid"
    mkdir -p "$DISPATCH_PROC/$pid"; printf 'HOME=/x\0AGENT_QUEUE_ITEM=%s\0' "$slug" > "$DISPATCH_PROC/$pid/environ"
  done
  stub pgrep "[ \"\$*\" = \"-u $(id -u) -f agent-codex (run|resume)\" ] || exit 2; for p in $pids; do echo \$p; done"
}

# --- tier 3 behind the red-fix gate (t3_picks) ---

# pr_lane_ready: the agent-runtime board, every gate passing.
pr_lane_ready() {
  project agent-runtime alpha "$SANDBOX/repos/app"
}

# pr_lane_verdict <key> [area] [fits] [size] [project] -- a tier-3 verdict under the current policy for the
# row's text: a dispatch, the tier-3 gate's to take, or with fits false an unclear skip
pr_lane_verdict() {
  mkdir -p "$FLEET_DISPATCH_DIR"
  jq -cn --arg p "${5:-agent-runtime}" --arg k "$1" --arg a "${2-$1}" --argjson fits "${3:-true}" --arg s "${4:-S}" --arg sig "$(policy_sig)" \
    --arg line "$(line_of "${5:-agent-runtime}" agent "$1")" \
    '{project: $p, lane: "agent", key: $k, verdict: (if $fits then "dispatch" else "skip" end), size: $s, tier: 3, area: $a,
      clear: $fits, agent_only: true, rule: (if $fits then "fits" else "unclear" end), reason: "tier 3", policy: $sig, line: $line}' \
    >> "$FLEET_DISPATCH_DIR/verdicts.jsonl"
}

state_of() { awk -F'\t' -v k="$1" '$1 == k { print substr($2, 1, 5) }' "$NOTES_FIXTURE/rows.agent-runtime.agent"; }

# pr_lane_keys -> the fixture names of the rows behind the queued tier-3 PR items (not the cleanup ones), sorted.
pr_lane_keys() {
  local id
  agent-queue list --json --state queued | jq -r 'select(((" " + (.tags // "") + " ") as $t | ($t | contains(" tier3 ")) and (($t | contains(" cleanup ")) | not))) | .from | ltrimstr("board:agent-runtime:")' |
    while read -r id; do awk -F'\t' -v q="id:$id " 'index($2, q) { print $1 }' "$NOTES_FIXTURE/rows.agent-runtime.agent"; done | sort | paste -sd, -
}

fill() { run "$REPO_ROOT/.local/bin/fleet-dispatch" fill "$@"; }

# --- the queue ---------------------------------------------------------------------------

qfield() { awk -v k="$2: " '$0 == "---" { exit } index($0, k) == 1 { print substr($0, length(k) + 1) }' "$1"; }
qitem() { ls "$AGENT_QUEUE_DIR"/"$1"/*-"$2".md 2>/dev/null; }

# pr_item <state> -- a board item on a gone session, its PR o/game#12 in <state> per the gh stub,
# its row started, and the project's checkout a real clone whose origin/main holds one commit (OID).
pr_item() {
  git init -q --bare "$SANDBOX/origin.git"
  git -c init.defaultBranch=main init -q "$SANDBOX/repos/game"
  git -C "$SANDBOX/repos/game" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix crash (#12)"
  git -C "$SANDBOX/repos/game" remote add origin "$SANDBOX/origin.git"
  git -C "$SANDBOX/repos/game" push -q origin HEAD:main
  OID=$(git -C "$SANDBOX/repos/game" rev-parse HEAD)
  project game beta "$SANDBOX/repos/game"
  row game agent 'fix crash' '- [/] fix crash'
  started_item fix-crash lab:game-agent-1 run '' 'board:game:fix crash'
  agent-queue set fix-crash pr=o/game#12 lane=agent >/dev/null
  printf '%s %s\n' "$1" "${2:-$OID}" > "$NOTES_FIXTURE/pr.state"
  gh_script 'printf "gh %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; [ -s "$NOTES_FIXTURE/pr.state" ] || exit 1; cat "$NOTES_FIXTURE/pr.state"'
}

# fj_item <state> <status> [merge sha] -- pr_item's fix-crash on a checkout whose canonical forge is
# Forgejo, as home-config is: it commits the mirror workflow, its `forgejo` remote is on a listed host
# and origin is the GitHub mirror, where gh finds no PR. Forgejo's API answers PR 12 as <state> (open,
# closed, merged) at head h1, with one check of <status> beside a green one.
fj_item() {
  pr_item OPEN
  mkdir -p "$SANDBOX/repos/game/.forgejo/workflows"; : > "$SANDBOX/repos/game/.forgejo/workflows/mirror-to-github.yaml"
  git -C "$SANDBOX/repos/game" remote add forgejo https://git.example.test/o/game.git
  # merge proof reads the forgejo remote's main, as fetched; https is refused, so its fetch leaves it as set here
  git -C "$SANDBOX/repos/game" update-ref refs/remotes/forgejo/main "$OID"
  export SO_CURL=curl-fj SO_FORGEJO_HOSTS=git.example.test GIT_ALLOW_PROTOCOL=file
  printf 'sekret-token' > "$RBW_FIXTURE/forgejo_repo_admin"
  gh_script 'printf "gh %s\n" "$*" >> "$NOTES_FIXTURE/calls.log"; exit 1'
  stub curl-fj 'url=${*: -1}; printf "%s\n" "$url" >> "$NOTES_FIXTURE/fj.urls"; printf "%s %s\n" "$url" "$(cat)" >> "$NOTES_FIXTURE/fj.auth"
case "$url" in */pulls/12) cat "$NOTES_FIXTURE/fj.pr" ;; */commits/*/status) cat "$NOTES_FIXTURE/fj.status" ;; *) exit 22 ;; esac'
  fj_pr "$1" "${3:-}"
  jq -cn --arg s "$2" '{state: $s, statuses: [{status: $s}, {status: "success"}]}' > "$NOTES_FIXTURE/fj.status"
}
# fj_pr <state> [merge sha] [body] -- what Forgejo's API says of PR 12
fj_pr() {
  jq -cn --arg st "$1" --arg m "${2:-$OID}" --arg b "${3:-Item: fix-crash}" '{number: 12, body: $b,
    state: (if $st == "open" then "open" else "closed" end), merged: ($st == "merged"),
    merge_commit_sha: (if $st == "merged" then $m else null end), head: {sha: "1111111111111111111111111111111111111111"}}' \
    > "$NOTES_FIXTURE/fj.pr"
}

# fix_ended <head> <ci> -- the fix-crash item's PR now reads OPEN at <head> with checks <ci>, and the
# item is back in review/ with a session that is gone, as a fix-ci session leaves it when it ends.
fix_ended() {
  printf 'OPEN - %s %s\n' "$1" "$2" > "$NOTES_FIXTURE/pr.state"
  [ "$(agent-queue show fix-crash --json | jq -r .state)" = review ] && return 0
  agent-queue move fix-crash running >/dev/null
  agent-queue set fix-crash session=lab:game-agent-1 >/dev/null
  agent-queue move fix-crash review >/dev/null
}

# codex_end_item <thread> <last turn event: json payload> [elapsed seconds] -- a Codex item on a gone session
# with no PR, its thread's rollout ending in that event, and a model-lane run for it. The launcher's
# timeout is 7200s. model-lane records its calls, so a test reads which outcome was filed.
codex_end_item() {
  local d="$HOME/.codex/sessions/2026/11/09"
  mkdir -p "$d" "$HOME/.local/lib"
  cp "$REPO_ROOT/.local/lib/codex-rollout.jq" "$HOME/.local/lib/codex-rollout.jq"
  CODEX_SESSIONS="$HOME/.codex/sessions"; CODEX_ROLLOUT_JQ="$HOME/.local/lib/codex-rollout.jq"
  jq -n '{harnesses: {codex: {source: "codex", headless: true, resume: true, timeout_min: 120, models: {sol: "gpt-6.1-sol"}}}}' > "$SANDBOX/harnesses.json"
  HARNESSES="$SANDBOX/harnesses.json"
  jq -cn --argjson e "$2" --arg first "$(date -u -d @1794200000 +%FT%T.000Z)" --arg last "$(date -u -d "@$((1794200000 + ${3:-60}))" +%FT%T.000Z)" \
    '{timestamp: $first, type: "event_msg", payload: {type: "task_started"}},
     {timestamp: $last, type: "event_msg", payload: {type: "token_count"}},
     (if $e == null then empty else {timestamp: $last, type: "event_msg", payload: $e} end)' > "$d/rollout-2026-11-09T07-33-20-$1.jsonl"
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"'
  project game beta "$SANDBOX/repos/game"
  started_item cx lab:game-agent-1 run
  agent-queue set cx agent=codex lane_run=r-cx >/dev/null; agent-queue claim cx --sid "$1" >/dev/null
}

# oc_session <session> <last assistant row: finish|error type|-> [elapsed seconds] -- that session in a fixture
# opencode.db at fleet-dispatch's default path under $HOME (OC_DB, beside its OC_SESSION_JQ): a user row, then
# an assistant row ending as given ("-" is neither).
oc_session() {
  local db="$HOME/.local/share/opencode/opencode.db" finish etype
  mkdir -p "$HOME/.local/lib" "${db%/*}"
  cp "$REPO_ROOT/.local/lib/opencode-session.jq" "$HOME/.local/lib/opencode-session.jq"
  OC_SESSION_JQ="$HOME/.local/lib/opencode-session.jq"; OC_DB="$db"
  IFS='|' read -r finish etype <<<"$2"
  rm -f "$db"
  sqlite3 "$db" "CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    INSERT INTO session_message VALUES ('m1', '$1', 'user', 1, 1794200000000, 1794200000000, '{\"text\":\"brief\"}');
    INSERT INTO session_message VALUES ('m2', '$1', 'assistant', 2, 1794200001000, $((1794200000000 + ${3:-60} * 1000)),
      json_object('finish', nullif('${finish:--}', '-'), 'error', CASE WHEN '${etype:--}' = '-' THEN NULL ELSE json_object('type', '$etype') END));"
}

# oc_end_item <session> <last assistant row: finish|error type|-> [elapsed seconds] -- an opencode item (harness
# go, timeout 7200s) on a gone session with no PR, its session as oc_session writes it, and a model-lane run for it.
oc_end_item() {
  oc_session "$@"
  jq -n '{harnesses: {go: {launcher: "opencode", source: "go", max_tier: 1, headless: true, timeout_min: 120, models: {glm: "go (glm-5.3)"}}}}' > "$SANDBOX/harnesses.json"
  HARNESSES="$SANDBOX/harnesses.json"
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"'
  project game beta "$SANDBOX/repos/game"
  started_item oc lab:game-agent-1 run
  agent-queue set oc agent=go lane_run=r-oc >/dev/null; agent-queue claim oc --sid "$1" >/dev/null
}

# ── orphan rows: started with no queue item ─────────────────────────────────
# orphan_seen <project> <key> <hours ago> -- reap first saw that agent row orphaned that long ago.
orphan_seen() {
  mkdir -p "$FLEET_DISPATCH_DIR"
  printf 'bnb\t%s\t%s\t%s\n' "$1" "$2" "$(( $(date +%s) - $3 * 3600 ))" >> "$FLEET_DISPATCH_DIR/orphans.tsv"
}

# landed_item <state> [pr] -- pr_item's item closed ok by its own session with no merged: recorded,
# as a --pr-only run left it before agent-queue refused that close (the store still holds those):
# the row stays started and no active item names it. The row file and calls.log are put back after the
# move, which now closes the row of an ok close with no PR.
landed_item() {
  pr_item "$1"
  agent-queue set fix-crash pr= >/dev/null
  cp "$NOTES_FIXTURE/rows.game.agent" "$SANDBOX/rows.kept"
  agent-queue move fix-crash done --status ok >/dev/null
  mv "$SANDBOX/rows.kept" "$NOTES_FIXTURE/rows.game.agent"
  sed -i '/--proof item:fix-crash/d' "$NOTES_FIXTURE/calls.log"
  agent-queue set fix-crash "pr=${2:-o/game#12}" >/dev/null
}

# bare_pr <body> -- landed_item with pr=12, and a gh that runs its real -q filter over a merged PR with
# that body, so the filter itself is under test.
bare_pr() {
  landed_item MERGED 12
  jq -n --arg o "$OID" --arg b "$1" '{state: "MERGED", mergeCommit: {oid: $o}, body: $b}' > "$NOTES_FIXTURE/pr.json"
  gh_script 'printf "gh %s in %s\n" "$(tr "\n" " " <<<"$*")" "$PWD" >> "$NOTES_FIXTURE/calls.log"; jq -r "${@: -1}" "$NOTES_FIXTURE/pr.json"'
}

# --- starved -----------------------------------------------------------------------------

# queued_item <slug> <priority> <queued> [tags] [after]
queued_item() {
  local d="$AGENT_QUEUE_DIR/queued"; mkdir -p "$d"
  {
    printf 'slug: %s\nproject: game\nmode: oneshot\npriority: %s\nfrom: human\nagent: claude\nqueued: %s\n' "$1" "$2" "$3"
    [ -z "${4:-}" ] || printf 'tags: %s\n' "$4"
    [ -z "${5:-}" ] || printf 'after: %s\n' "$5"
    printf -- '---\n%s\n' "$1"
  } > "$d/20261103-100000-$1.md"
}

# hold_for <minutes ago> <why>: the hold agent-proof.sh keeps for fleet-dispatch.
hold_for() {
  local d="$HOME/.local/state/agentctl/fleet-dispatch"; mkdir -p "$d"
  echo "$(( $(date +%s) - $1 * 60 ))" > "$d/held_since"; printf '%s' "$2" > "$d/held_why"
}

# board_item <slug> <queued>: a queued high item promoted from a board row
board_item() {
  queued_item "$1" high "$2"
  sed -i "s/^from: human/from: board:game:$1/" "$AGENT_QUEUE_DIR/queued/20261103-100000-$1.md"
}

# world <instance> <pane lines...> -- what a stub server answers; no instance is a server that is down.
world() {
  printf '%s' "$1" > "$NOTES_FIXTURE/world.instance"; shift
  printf '%s\n' "$@" > "$NOTES_FIXTURE/world.panes"
}

record_setup() {
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR" "$HOME/.claude/sessions"
  : > "$TMUX_SERVERS_DIR/hub.conf"
  tmux_script 'case "$*" in
    *display-message*) [ -s "$NOTES_FIXTURE/world.instance" ] || exit 1; cat "$NOTES_FIXTURE/world.instance"; echo ;;
    *list-panes*) cat "$NOTES_FIXTURE/world.panes" ;;
  esac'
  stub agent-notify 'echo "agent-notify $*" >> "$NOTES_FIXTURE/calls.log"'
  stub agent-panel 'cat "$NOTES_FIXTURE/panel.json"'
  echo '{"pane":"hub/%1","session_id":"conv-1","cwd":"/work/tree"}' > "$NOTES_FIXTURE/panel.json"
  PANE1=$'%1\tdotfiles\tcrash\t/shell/dir' PANE2=$'%2\tdotfiles\tzsh\t/plain/dir'
  RECORD="$FLEET_DISPATCH_DIR/panes/hub.json" LOST="$FLEET_DISPATCH_DIR/panes/hub.lost.json"
}

# lost_pane <window> <cwd> <id> -- one more pane on the lost hub record.
lost_pane() {
  local f="$FLEET_DISPATCH_DIR/panes/hub.lost.json"
  mkdir -p "${f%/*}"
  [ -f "$f" ] || echo '{"server":"hub","instance":"1 1","panes":[]}' > "$f"
  jq --arg w "$1" --arg c "$2" --arg i "$3" '.panes += [{session: "dotfiles", window: $w, cwd: $c, claude: $i}]' "$f" > "$f.new"
  mv "$f.new" "$f"
}

transcript() {
  mkdir -p "$HOME/.claude/projects/some-project"
  printf '%s\n' "$2" > "$HOME/.claude/projects/some-project/$1.jsonl"
}

restore_setup() {
  project game beta "$SANDBOX/repos/game"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR" "$HOME/.claude/sessions" "$HOME/.agent/spin-down"
  stub tmx 'echo "tmx $*" >> "$NOTES_FIXTURE/calls.log"'
  stub agent-panel 'exit 0'
  printf 'dotfiles\n' > "$NOTES_FIXTURE/tmux.sessions.hub"
}

# --- gateway harnesses: `start --harness` ---------------------------------------------------

# src_shut <source> <why> -- claude-acct room --source refuses <source> with <why>
src_shut() { printf '%s\n' "$2" > "$NOTES_FIXTURE/src.$1"; }

# route_spent <gateway model> <why> -- claude-acct room --source <any> --model <gateway model> refuses
# with <why>, the source's own row still ok: a deployment budget spent under a key with room.
route_spent() { printf '%s\n' "$2" > "$NOTES_FIXTURE/route.$(printf %s "$1" | tr -c 'A-Za-z0-9._-' _)"; }

# harness_set [jq args] <filter> -- edit the harness map in place.
harness_set() { jq "$@" "$DISPATCH_HARNESSES" > "$SANDBOX/h.tmp" && mv "$SANDBOX/h.tmp" "$DISPATCH_HARNESSES"; }

# A harness map whose harnesses each name the source they spend; claude-acct says every source has room.
harness_ready() {
  game_ready
  printf 'sk-test\n' > "$SANDBOX/eval.key"
  printf 'sk-paid\n' > "$SANDBOX/paid.key"
  jq -n --arg k "$SANDBOX/eval.key" --arg c "$SANDBOX/eval.json" --arg gk "$SANDBOX/paid.key" --arg gc "$SANDBOX/eval-paid.json" '{
    gateway: {url: "https://gw.test", key_file: $k},
    harnesses: {
      "claude-lazer": {source: "eval", timeout_min: 180, models: {sonnet: "sonnet"}},
      opencode: {source: "eval", headless: true, config: $c, timeout_min: 180, models: {sonnet: "litellm/claude-sonnet-5", qwen: "litellm/code (qwen-3-coder)"}},
      paid: {launcher: "opencode", source: "paid", headless: true, metered: true, config: $gc, key_file: $gk, timeout_min: 180, models: {glm: "litellm/reasoning (glm-5.3)"}},
      codex: {source: "codex", headless: true, resume: true, timeout_min: 120, models: {sol: "gpt-6.1-sol"}},
      "claude-cloud": {launcher: "claude-cloud", timeout_min: 90, models: {cloud: "cloud"}}}}' > "$SANDBOX/harnesses.json"
  export DISPATCH_HARNESSES="$SANDBOX/harnesses.json"
  # The kinds route() keeps off a headless harness, at the path the script reads by default.
  mkdir -p "$HOME/.config/fleet-bench"
  jq -n '{kinds: ["fix"], stacks: {shell: {projects: ["game"]}, unity: {projects: ["arena"]}}, modes: [],
    excluded: [{kind: "deploy", match: "\\b(deploy(s|ed|ing|ment)?|kubectl)\\b", why: "human-gated"},
      {kind: "secrets", match: "\\b(secrets?|rbw|sops)\\b", why: "secrets"},
      {kind: "prod", match: "\\b(prod|production)\\b", why: "prod"},
      {kind: "unity-editor", stack: "unity", match: "(^|[[:space:]])#requested\\b|\\b(editor|play ?mode)\\b", why: "needs the editor"},
      {kind: "host-ops", match: "\\b(drain(s|ed|ing)?\\b.*\\b(runners?|hosts?)|(runners?|hosts?)\\b.*\\bdrain(s|ed|ing)?|(de|un)-?regist(er|ers|ered|ering|ration)\\b.*\\brunners?|runners?\\b.*\\b(de|un)-?regist(er|ers|ered|ering|ration)|runners? (registration|token)s?|regist(er|ers|ered|ering|ration) (of )?(the |a |its |their )?(self-hosted |org |github )?runners?|systemctl( +-[^ ]+)* +(stop|disable|mask|kill|restart|reboot|poweroff|halt))\\b", why: "live host ops"},
      {mode: "fleet-worker", why: "no match, so never read by route"},
      {mode: "lane-sandbox", why: "no match, so never read by route"}]}' > "$HOME/.config/fleet-bench/matrix.json"
  stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; [ "$1" != log ] || echo run-9'
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  tmux_script 'exit 0'
  agent-queue add --project game --slug fix-menu --priority high "Fix the menu sides" >/dev/null
}

# --- lane sandbox: DISPATCH_SANDBOX_PROFILE (the pattern is tests/integ/agent_run_sandbox.bats) ---

# A repo with a worktree-able git dir, and a profile that tries to switch every hard gate off.
sandbox_ready() {
  project game beta "$SANDBOX/repos/game"
  git init -q "$SANDBOX/repos/game"
  export AGENTCTL_SANDBOX_DIR="$SANDBOX/sbx"
  SANDBOX_DIR=$AGENTCTL_SANDBOX_DIR   # lib/sandbox.sh read it when this file was sourced
  mkdir -p "$AGENTCTL_SANDBOX_DIR"
  cat > "$AGENTCTL_SANDBOX_DIR/lane.json" <<'JSON'
{"sandbox": {"enabled": false, "failIfUnavailable": false, "allowUnsandboxedCommands": true,
  "network": {"allowedDomains": ["github.com"], "strictAllowlist": false},
  "filesystem": {"denyRead": ["~/.ssh", "/etc/fake-cred"], "allowWrite": ["~/.agent"]}},
 "permissions": {"deny": ["Bash(rm -rf /)"]}}
JSON
  stub wt 'printf "%s\n" "$WT_NEW_CMD" >> "$NOTES_FIXTURE/cmds.log"; echo "game-agent-1"'
}
# launch_settings -> the JSON the last launch line passed to --settings
launch_settings() { eval "printf %s $(grep -m1 -e '--settings' "$NOTES_FIXTURE/cmds.log" | sed -E 's/.* --settings (.*) --permission-mode.*/\1/')"; }

# harness_sandboxed <harness> -- the harness names lane sandbox "pub", held by srt (a stub; the
# start never runs it, the pane would). Its config exists, since the launch names it by its target.
harness_sandboxed() {
  export AGENTCTL_SANDBOX_DIR="$SANDBOX/sbx" SANDBOX_SRT_NEEDS=srt
  mkdir -p "$AGENTCTL_SANDBOX_DIR"
  printf '%s\n' '{"sandbox": {"filesystem": {"denyRead": ["~/", "/tmp"], "allowWrite": []}, "network": {"allowedDomains": ["gw.test"]}}}' \
    > "$AGENTCTL_SANDBOX_DIR/pub.json"
  stub srt 'exit 0'
  stub opencode 'exit 0'   # harness_ready_why wants it on PATH; the pane, never the start, runs it
  harness_set --arg h "$1" '.harnesses[$h].sandbox = "pub"'
  touch "$(jq -r --arg h "$1" '.harnesses[$h].config' "$DISPATCH_HARNESSES")"
}

# canary_item <slug> <canary id> -- the queued item is a fleet-bench canary that names its task.
canary_item() { agent-queue set "$1" tags=canary canary="$2" >/dev/null; }

# --- claude-cloud: a #cloud-ok item runs as a Claude cloud session ---------------------------

cloud_ready() {
  harness_ready
  git -C "$SANDBOX/repos/game" init -q
  git -C "$SANDBOX/repos/game" remote add origin git@github.com:acme/game.git
  agent-queue add --project game --slug cloud-fix --priority high --tags cloud-ok "Fix the menu text" >/dev/null
}

# claude-cloud-run: claude, gh and script are stubs; the real agent-queue records the PR.
cloud_run_ready() {
  agent-queue add --project game --slug cloud-fix --priority high --tags cloud-ok "Fix the menu text" >/dev/null
  agent-queue move cloud-fix running >/dev/null
  stub claude 'echo "claude $*" >> "$NOTES_FIXTURE/calls.log"; echo "Session: https://claude.ai/code/session_01AbC"'
  gh_script 'echo "gh $*" >> "$NOTES_FIXTURE/calls.log"; cat "$NOTES_FIXTURE/prs.json"'
  export CLOUD_POLL_SEC=0 CLAUDE_BIN=claude
}

# codex_ran <slug> <thread> [salvage] -- a queued item whose last run, on codex, claimed that thread,
# whose rollout is on disk; salvage: is set when given.
codex_ran() {
  local d="$HOME/.codex/sessions/2026/11/09"
  mkdir -p "$d"; : > "$d/rollout-2026-11-09T07-33-20-$2.jsonl"
  export DISPATCH_CODEX_SESSIONS="$HOME/.codex/sessions"
  agent-queue set "$1" agent=codex model=sol ${3:+"salvage=$3"} >/dev/null
  agent-queue claim "$1" --sid "$2" >/dev/null
}

# --- routing: a run pass over every source ------------------------------------------------

# Every account past its pace, lazer-reserve on its own key, and model-lane putting every task on
# Sonnet ($LANE when set), whose candidates are claude and codex at one fit and lazer-reserve at the
# next. Opus's are lanes.yaml's: claude, then codex at the next fit. No source has room until
# a test says which (srcs).
route_ready() {
  harness_ready
  printf 'sk-reserve\n' > "$SANDBOX/reserve.key"
  harness_set --arg k "$SANDBOX/reserve.key" '.harnesses["lazer-reserve"] = {launcher: "claude-lazer", source: "reserve", key_file: $k, timeout_min: 180, models: {sonnet: "sonnet"}}'
  acct "alt:pace:/home/u/.claude-personal:4 points over its weekly pace"
  srcs
  sonnet_lane
}
# sonnet_lane -- model-lane stubbed: classify places LANE (sonnet) with lanes.yaml's fits; with LANE_PROMOTED=<harness:model>
# the verdict promoted that pair for the class, as model-lane score does a trainee's: it leads the first fit, in `direct`.
sonnet_lane() { stub model-lane 'echo "model-lane $*" >> "$NOTES_FIXTURE/calls.log"; l=${LANE:-sonnet}
case "$1" in log) echo run-9 ;; trainee) printf "%s\n" "${TRAINEE_LANE:-}" ;; classify)
  if [ "$l" = opus ]; then c="[{\"harness\":\"claude\",\"model\":\"opus\",\"fit\":0},{\"harness\":\"codex\",\"model\":\"sol\",\"fit\":1}]"
  elif [ "$l" = sonnet ]; then c="[{\"harness\":\"claude\",\"model\":\"sonnet\",\"fit\":0},{\"harness\":\"codex\",\"model\":\"sol\",\"fit\":0},{\"harness\":\"lazer-reserve\",\"model\":\"sonnet\",\"fit\":1}]"
  else c="[{\"harness\":\"claude\",\"model\":\"$l\",\"fit\":0}]"; fi
  p="[]"; if [ -n "${LANE_PROMOTED:-}" ]; then p="[\"$LANE_PROMOTED\"]"
    c="[{\"harness\":\"${LANE_PROMOTED%%:*}\",\"model\":\"${LANE_PROMOTED#*:}\",\"fit\":0},${c#[}"; fi
  echo "{\"lane\":\"$l\",\"by\":\"rule\",\"model\":\"$l\",\"dispatch_model\":\"$l\",\"candidates\":$c,\"promoted\":[],\"direct\":$p}" ;; esac'; }

# --- fleet workers -----------------------------------------------------------------------

# worker <load cores ready mem% [conflict [notes]]> [place] [first] [harnesses] [kit] -- one fleet worker, razer-laptop, in an inventory whose
# ansible_host sits in another group and that lists the workstation, state, with the game repo cloned. ssh answers its probe with those
# four words (a fifth, 1, says its store is in a merge conflict; a sixth, 0, that it has no ~/.notes clone) and runs any other command here, so the tmux stub stands in for the worker's server.
# ssh.rc, when present, is ssh's own exit (255: the worker did not answer).
# first is its fleet_first, a YAML list such as "[canary]"; harnesses its fleet_harnesses, such as "[ocfree]";
# kit its `fleet-dispatch kit` line, default every launcher and srt ("" is an older worker with no kit verb).
worker() {
  export FLEET_INVENTORY="$SANDBOX/inventory.yml"
  cat > "$FLEET_INVENTORY" <<EOF
all:
  children:
    desktops:
      hosts:
        state: {}
    laptops:
      hosts:
        razer-laptop:
          ansible_host: 192.0.2.26
          ansible_user: kb
    fleet_workers:
      vars:
        fleet_max_live: 1
        fleet_place: ${2:-true}
      hosts:
        razer-laptop:
          fleet_first: ${3:-[]}
          fleet_harnesses: ${4:-[]}
          fleet_repos:
            - dest: "$SANDBOX/repos/game"
              repo: game
EOF
  printf '%s\n' "${5-claude codex opencode srt}" > "$NOTES_FIXTURE/ssh.kit"
  { tr ' ' '\n' <<<"$1"; echo kit; cat "$NOTES_FIXTURE/ssh.kit"; } > "$NOTES_FIXTURE/ssh.probe"
  stub ssh 'echo "ssh $*" >> "$NOTES_FIXTURE/calls.log"
[ ! -e "$NOTES_FIXTURE/ssh.rc" ] || exit "$(cat "$NOTES_FIXTURE/ssh.rc")"
eval "set -- ${*: -1}"
case "$1 ${2:-}" in "sh -c") cat "$NOTES_FIXTURE/ssh.probe" ;; "fleet-dispatch kit") cat "$NOTES_FIXTURE/ssh.kit" ;; *) "$@" ;; esac'
  # The worker's fleet-dispatch is this checkout's, never the one deployed on this machine's PATH.
  stub fleet-dispatch "exec '$REPO_ROOT/.local/bin/fleet-dispatch' \"\$@\""
  stub wt 'echo "wt $* :: $WT_NEW_CMD" >> "$NOTES_FIXTURE/calls.log"; echo "game-agent-1"'
  # The start's push here and the worker's pull (systemd-run, run here by the ssh stub);
  # systemd-run.rc, when present, is the pull's exit.
  stub store-sync 'echo "store-sync $*" >> "$NOTES_FIXTURE/calls.log"'
  stub systemd-run 'echo "systemd-run $*" >> "$NOTES_FIXTURE/calls.log"; exit "$(cat "$NOTES_FIXTURE/systemd-run.rc" 2>/dev/null || echo 0)"'
  unset FLEET_HOSTS_JSON
}

# remote_item <slug> -- a started item on lab:game-agent-1 at razer-laptop.
remote_item() {
  started_item "$1" lab:game-agent-1 run
  sed -i 's/^session: .*/&\nhost: razer-laptop/' "$(qitem running "$1")"
}

# --- focus: #prio/focus ------------------------------------------------------------------

# focus_on <project>... -- the human put each on `#prio/focus`: the `notes projects --prios` line agent-queue
# and fleet-dispatch read, and the front-page head tag prio_of reads (the one store both come from).
focus_on() {
  local p
  for p; do
    printf '%s\tfocus\n' "$p" >> "$NOTES_FIXTURE/prios"
    sed -i '1s/$/ #prio\/focus/' "$SANDBOX/sheets/$p/README.md"
  done
}

# ocfree: a free harness whose provider may train on prompts, allowlisted to the public project only.
ocfree_ready() {
  printf 'sk-ocfree\n' > "$SANDBOX/ocfree.key"
  harness_set --arg k "$SANDBOX/ocfree.key" --arg c "$SANDBOX/eval-ocfree.json" --arg d "$SANDBOX/oc-ocfree" '.harnesses.ocfree = {
    launcher: "opencode", source: "ocfree", headless: true, config: $c, config_dir: $d, key_file: $k, projects: ["dotfiles"], timeout_min: 180, models: {beam: "litellm/opencode-free (beam-free)"}}'
  harness_sandboxed ocfree
}

# trainee_ready -- a trainee lane (model-lane trainee, lanes.yaml trainee:) of two models on gotrain, a
# sandboxed harness allowlisted to game whose source has room; no claude account has room (route_ready).
# HARNESSES is the map a function the test calls directly reads (fleet-dispatch set it at load, before this map).
trainee_ready() {
  route_ready
  HARNESSES=$DISPATCH_HARNESSES
  printf 'sk-go\n' > "$SANDBOX/go.key"
  harness_set --arg k "$SANDBOX/go.key" --arg c "$SANDBOX/eval-go.json" --arg d "$SANDBOX/oc-go" '.harnesses.gotrain = {
    launcher: "opencode", source: "go", headless: true, max_tier: 1, config: $c, config_dir: $d, key_file: $k, projects: ["game"], timeout_min: 60,
    models: {glm: "litellm/go (glm)", kimi: "litellm/go (kimi)"}}'
  harness_sandboxed gotrain
  trainee_repo "$SANDBOX/repos/game"
  srcs go:ok:0.1 codex:ok:5
  export TRAINEE_LANE='{"candidates":[{"harness":"gotrain","model":"glm"},{"harness":"gotrain","model":"kimi"}],"points":1,"reviewer":"opus","reviewer_model":"opus"}'
}

# gateway_up -- the gateway's /health/readiness answers healthy, as LiteLLM does with its db connected.
gateway_up() { stub curl 'echo "curl $*" >> "$NOTES_FIXTURE/calls.log"; echo "{\"status\":\"healthy\",\"db\":\"connected\"}"'; }
