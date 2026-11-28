#!/usr/bin/env bats
# QUEUE.md (private overlay, ~/.config/agentctl/) defines eight rows of ARCHITECTURE.md's Flows
# table: Work intake, Queue states, Admission, the Fleet lease, Intake channels, Outbox to
# board, Red triage and Alert ownership. Its Proposals section is no Flows row: no watch could
# probe it (QUEUE.md "Proposals"). Each test here reads
# one section's enumerable facts (a state, a source, a verb, a default, a lane) and the code that
# implements it, from the files as text, so the section cannot drift from agent-queue,
# fleet-dispatch or fleet-lease unseen. Change the code and its section together.
# Skipped where the private overlay is absent (this repo's CI); the private repo runs it through
# .github/workflows/queue-doc.yml, on its PRs and pushes and daily, where no case may skip (ar-4243).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  PUB="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PRIV="${QUEUE_DOC_PRIVATE_REPO:-${ACCOUNT_HOME:-/nonexistent}/.dotfiles-private}"
  DOC="$PRIV/.config/agentctl/QUEUE.md"
  [ -f "$DOC" ] || skip "no private overlay at $PRIV"
  AQ="$PUB/.local/bin/agent-queue"
  FD="$PUB/.local/bin/fleet-dispatch"
  LAND="$PUB/.local/bin/agent-land"
  FL="$PUB/.local/bin/fleet-lease"
}

# section <heading>: the body of `## <heading>` up to the next level-2 heading.
section() {
  awk -v h="## $1" '$0 == h {f=1; next} f && /^## / {exit} f' "$DOC"
}

# default_of <file> <var>: N from `VAR="${ENV:-N}"` or `: "${VAR:=N}"`.
default_of() {
  sed -nE "s/^$2=\"\\\$\{[A-Z_]+:-([0-9]+)\}\".*/\1/p; s/^: \"\\\$\{$2:=([0-9]+)\}\".*/\1/p" "$1" | head -n 1
}

# The States table's first column, as bare names (`done/<date>/` is done).
doc_states() {
  section States | grep -oE '^\| `[a-z]+/' | sed 's/^| `//; s#/$##' | sort
}

@test "Queue states: the States table is agent-queue's live states plus done" {
  local active
  active=$(sed -nE 's/^ACTIVE="([a-z ]+)"$/\1/p' "$AQ")
  [ -n "$active" ]
  run diff <(doc_states) <(printf '%s\n' $active done | sort)
  assert_success
}

@test "Work intake: the flow diagram walks the same queue states as the States table" {
  local line
  line=$(section 'The flow: inbox to ledger' | grep -m1 'queue item:')
  [ -n "$line" ]
  run diff <(sed -E 's/.*queue item: //; s/ \([^)]*\)//g; s#/<date>/##; s/ (->|or) /\n/g' <<<"$line" | sort) <(doc_states)
  assert_success
}

@test "Admission: every add source the cap never holds is named in the section" {
  local srcs s body
  srcs=$(sed -nE 's/^ *case "\$from" in ([a-z: |]+)\) capped=.*/\1/p' "$AQ" | tr -d ' ' | tr '|' '\n')
  [ -n "$srcs" ]
  body=$(section Admission)
  for s in $srcs; do
    grep -qF "\`$s\`" <<<"$body" || { echo "not in QUEUE.md Admission: \`$s\`"; return 1; }
  done
}

@test "Admission: the AGENT_QUEUE_PULL values the section names are the ones fleet-dispatch and agent-land set" {
  local code
  code=$({
    grep -ohE 'AGENT_QUEUE_PULL="?\$?\{?(PULL:-)?[a-z]+' "$FD" "$LAND" | grep -oE '[a-z]+$'
    sed -nE 's/^start_pull\(\) \{.*&& echo ([a-z]+) \|\| echo ([a-z]+);.*/\1\n\2/p' "$FD"
  } | sort -u)
  [ -n "$code" ]
  run diff <(section Admission | grep -oE 'AGENT_QUEUE_PULL=[a-z]+' | sed 's/.*=//' | sort -u) <(echo "$code")
  assert_success
}

@test "Admission: the board-only exit and the cap default are agent-queue's" {
  local body
  body=$(section Admission)
  [ "$(grep -oE 'exit [0-9]+, `why: board-only`' <<<"$body" | grep -oE '[0-9]+')" = "$(sed -nE 's/^AQ_EX_HELD=([0-9]+)$/\1/p' "$AQ")" ]
  [ "$(grep -oE '`AGENT_QUEUE_CAP` \(default [0-9]+\)' <<<"$body" | grep -oE '[0-9]+')" = "$(default_of "$AQ" AQ_CAP)" ]
}

@test "Dispatch: the low water fleet-dispatch.md names is the agentctl conf's" {
  local body
  body=$(cat "$PUB/.local/src/docs/fleet-dispatch.md")
  [ "$(grep -oE 'DISPATCH_LOW_WATER` \([0-9]+\)' <<<"$body" | grep -oE '[0-9]+')" = "$(sed -n 's/^DISPATCH_LOW_WATER=\([0-9]*\).*/\1/p' "$PRIV/.config/agentctl/agents/fleet-dispatch.conf")" ]
}

@test "Fleet lease: the fleet-dispatch verbs it names are the ones lease_guard covers" {
  local code doc
  code=$(awk '/^main\(\) \{/ {f=1} f && /lease_guard "\$1"/ {print} f && /^  esac/ {exit}' "$FD" |
    sed -E 's/^ *//; s/\).*//' | tr -d ' ' | tr '|' '\n' | sort)
  [ -n "$code" ]
  doc=$(section 'The fleet lease' | grep -m1 -oE '`fleet-dispatch run`[^(]*check the same lease' |
    grep -oE '`[a-z -]+`' | tr -d '`' | sed 's/^fleet-dispatch //' | sort)
  [ -n "$doc" ] || { echo "QUEUE.md 'The fleet lease' lost its '\`fleet-dispatch run\`, ... check the same lease' sentence"; return 1; }
  run diff <(echo "$doc") <(echo "$code")
  assert_success
}

@test "Fleet lease: the TTL and the no-network margin are fleet-lease's" {
  local body
  body=$(section 'The fleet lease')
  [ "$(grep -oE 'TTL [0-9]+ s' <<<"$body" | grep -oE '[0-9]+')" = "$(default_of "$FL" TTL_S)" ]
  [ "$(grep -oE 'more than [0-9]+ s from expiry' <<<"$body" | grep -oE '[0-9]+')" = "$(sed -nE 's/^MARGIN_S=([0-9]+)$/\1/p' "$FL")" ]
}

@test "Fleet lease: the lanes with no conf are the units gated on fleet-lease by name" {
  local units doc
  units=$(for r in "$PUB" "$PRIV"; do
    git -C "$r" ls-files -z '.config/systemd/user/*.service' | (cd "$r" && xargs -0 cat)
  done | sed -nE 's#^ExecCondition=%h/\.local/bin/fleet-lease ([a-z0-9-]+)$#\1#p' | sort -u)
  [ -n "$units" ]
  doc=$(section 'The fleet lease' | grep -m1 -oE 'A lane with no conf \([^)]*\)' |
    sed -E 's/.*\(//; s/\)$//' | tr ',' '\n' | tr -d ' ' | sort)
  [ -n "$doc" ] || { echo "QUEUE.md 'The fleet lease' lost its 'A lane with no conf (...)' list"; return 1; }
  run diff <(echo "$doc") <(echo "$units")
  assert_success
}

@test "Fleet lease: the persistent singletons it names are fleet-lease's UNITS plus the persistent singleton confs" {
  local code doc
  code=$({
    sed -nE 's/^UNITS="\$\{FLEET_LEASE_UNITS:-([^}]*)\}"$/\1/p' "$FL" | tr ' ' '\n' | sed 's/\.service$//'
    for f in "$PRIV"/.config/agentctl/agents/*.conf; do
      grep -qE '^KIND=["'\'']?persistent' "$f" && ! grep -qE '^SCOPE=["'\'']?every-node' "$f" && basename "$f" .conf
    done
  } | grep -v '^$' | sort -u)
  [ -n "$code" ]
  doc=$(section 'The fleet lease' | grep -m1 -oE 'the persistent singletons \([^)]*\)' |
    sed -E 's/.*\(//; s/\)$//' | tr ',' '\n' | tr -d ' ' | sort)
  [ -n "$doc" ] || { echo "QUEUE.md 'The fleet lease' lost its 'the persistent singletons (...)' list"; return 1; }
  run diff <(echo "$doc") <(echo "$code")
  assert_success
}

# Intake channels: the table is the one list of doors into the fleet (ar-4152). The scanner is
# tests/helpers/intake_callers.pl; both repos' checkouts are read, the private one being $PRIV.

# intake_files: the files the table's first column names, one path a line. A path starts with a dot
# and has a slash, so a command in a backtick (`agent-queue add`) and a route (`/api/send`) are not one.
intake_files() {
  section 'Intake channels' | grep -E '^\| ' | awk -F' [|] ' '{print $1}' | grep -oE '`\.[A-Za-z0-9_./-]+/[A-Za-z0-9_./-]+`' | tr -d '`' | sort -u
}

@test "Intake channels: every file that runs agent-queue add or notes ptask add is a row of the table" {
  local found f
  found=$({ perl "$PUB/tests/helpers/intake_callers.pl" "$PUB"; perl "$PUB/tests/helpers/intake_callers.pl" "$PRIV"; } | sort -u)
  [ -n "$found" ]
  for f in $found; do
    intake_files | grep -qxF "$f" || { echo "not in QUEUE.md Intake channels: $f (add its row: entry, writer, from or origin, owner, checked by)"; return 1; }
  done
}

@test "Intake channels: every file the table names exists in one of the repos" {
  local f
  [ -n "$(intake_files)" ]
  for f in $(intake_files); do
    [ -e "$PUB/$f" ] || [ -e "$PRIV/$f" ] || { echo "QUEUE.md Intake channels names a file that is gone: $f"; return 1; }
  done
}

@test "Intake channels negative control: a new caller shows up, and a comment, a message and a hint do not" {
  local root="$BATS_TEST_TMPDIR/scan"
  mkdir -p "$root/.local/bin" "$root/.claude/hooks"
  printf '#!/usr/bin/env bash\nout="$(agent-queue add --project x "y")"\n' > "$root/.local/bin/new-filer"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$t" | agent-queue add --project x\n' > "$root/.local/bin/piped-filer"
  printf '#!/usr/bin/env bash\nAGENT_QUEUE_PULL=dispatch agent-queue add --plan p\n' > "$root/.local/bin/env-filer"
  printf '#!/usr/bin/env bash\nnotes ptask "$p" --agent add -- "$row"\n' > "$root/.claude/hooks/ptask-filer"
  printf '#!/usr/bin/env bash\n# agent-queue add --project x\ndie "no item: run agent-queue add --running first"\necho "notes ptask <project> --agent add"\n' > "$root/.local/bin/hint-only"
  printf 'import subprocess\nsubprocess.run(["agent-queue", "add", "--project", p])\n' > "$root/.local/bin/list-filer.py"
  printf '#!/usr/bin/env bash\nnotes focus add "x"\nagent-queue list --add\n' > "$root/.local/bin/other-notes"
  run perl "$PUB/tests/helpers/intake_callers.pl" "$root"
  assert_success
  assert_output $'.claude/hooks/ptask-filer\n.local/bin/env-filer\n.local/bin/list-filer.py\n.local/bin/new-filer\n.local/bin/piped-filer'
}

@test "Intake channels: the writer classes name the environment notes-cli reads, and the section is the one that says it" {
  local body v
  body=$(section 'Intake channels')
  for v in CLAUDE_CODE_SESSION_ID AGENT_QUEUE_ITEM AGENTCTL_NAME; do
    grep -qF "\`$v\`" <<<"$body" || { echo "Intake channels does not name $v"; return 1; }
    grep -rqF "\"$v\"" "$PUB/.local/src/notes-cli/src" || { echo "notes-cli no longer reads $v"; return 1; }
  done
  grep -qF 'agent_direct_filers' <<<"$body" || { echo "Intake channels does not name agent_direct_filers"; return 1; }
}

@test "Flows: every ARCHITECTURE.md row defined in QUEUE.md names a heading that exists" {
  local arch="$PRIV/.config/agentctl/ARCHITECTURE.md" a slugs
  slugs=$(grep -E '^#{2,4} ' "$DOC" | sed -E 's/^#+ //' | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g')
  for a in $(grep -oE 'QUEUE\.md#[a-z0-9_-]+' "$arch" | sed 's/.*#//' | sort -u); do
    grep -qxF "$a" <<<"$slugs" || { echo "ARCHITECTURE.md Flows names QUEUE.md#$a, which is no heading"; return 1; }
  done
}

@test "Proposals: the expiry ask QUEUE.md promises is the one agent-propose sends" {
  grep -qF '(`ask_expiring`)' "$DOC" || { echo "QUEUE.md Proposals no longer names ask_expiring: update this test with it"; return 1; }
  grep -qE '^ask_expiring\(\)' "$PUB/.local/bin/agent-propose" || { echo "agent-propose has no ask_expiring, which QUEUE.md Proposals names"; return 1; }
  grep -qE 'ask="\$\(ask_expiring ' "$PUB/.local/bin/agent-propose" || { echo "agent-propose sweep no longer asks on expiry"; return 1; }
}

@test "Flows: the intake rows are in ARCHITECTURE.md, each at the heading that defines it" {
  local arch="$PRIV/.config/agentctl/ARCHITECTURE.md" a
  for a in intake-channels outbox-to-board red-triage alert-ownership; do
    grep -qF "QUEUE.md#$a" "$arch" || { echo "ARCHITECTURE.md has no Flows row for QUEUE.md#$a"; return 1; }
  done
}
