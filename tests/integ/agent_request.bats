#!/usr/bin/env bats
# agent-request: file:line notes gathered into one draft per repo, sent as one agent-queue item
# or one `@file` line typed into the repo's Claude pane. agent-queue and agent-panel are stubs
# that log to calls.log; git is real, on a throwaway repo.

setup() {
  bats_require_minimum_version 1.5.0
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  AR="$REPO_ROOT/.local/bin/agent-request"
  export PROJECT_NAME_LIB="$REPO_ROOT/.config/shared-hooks/project-name.sh"   # for the PATH copy
  export AGENT_PANE_LIB="$REPO_ROOT/.local/lib/agent-pane.sh"
  REPO="$SANDBOX/repo"
  mkdir -p "$REPO/cfg"
  printf '{\n  "spawnRate": 3,\n  "max": 10\n}\n' > "$REPO/cfg/a.json"
  git -C "$REPO" init -q
  git -C "$REPO" add .
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
  cat > "$SANDBOX/bin/agent-queue" <<'EOF'
#!/usr/bin/env bash
printf 'agent-queue %s\n' "$*" >> "$NOTES_FIXTURE/calls.log"
cat > "$NOTES_FIXTURE/queue.stdin"
[ -f "$NOTES_FIXTURE/queue.fail" ] && exit 1
echo "queued demo-slug -> /queue/demo-slug.md"
EOF
  chmod +x "$SANDBOX/bin/agent-queue"
  cp "$AR" "$SANDBOX/bin/agent-request"   # nvim finds it on PATH; copied, never linked
  cd "$REPO"
}

two_notes() {
  "$AR" add --file cfg/a.json --line 2 --end 3 -- "raise spawn: to 5"
  "$AR" add --file "$REPO/cfg/a.json" --line 3 "max to 20"
}

pane_row() { # <cwd> <pane> [status]
  printf '{"cwd":"%s","pane":"%s","target":"hub/x:1","doing":"","status":"%s"}\n' "$1" "$2" "${3:-idle}"
}

@test "add then list round-trips, quoting the lines each note points at" {
  two_notes
  run "$AR" list
  assert_success
  assert_line "$REPO/cfg/a.json:2: raise spawn: to 5"
  assert_line "$REPO/cfg/a.json:3: max to 20"
  run cat "$("$AR" path)"
  assert_line '    >   "spawnRate": 3,'
}

@test "an --id already in the draft is not added twice" {
  "$AR" add --file cfg/a.json --line 3 --id hunk:n1 "max to 20"
  run "$AR" add --file cfg/a.json --line 3 --id hunk:n1 "max to 20"
  assert_output --partial 'already in the request'
  run "$AR" list --json
  assert_equal "$(jq length <<< "$output")" 1
  assert_equal "$(jq -r '.[0].id' <<< "$output")" hunk:n1
}

@test "send --queue puts every note in one human item and archives the draft" {
  two_notes
  run "$AR" send --queue
  assert_success
  assert_output --partial 'queued demo-slug'
  run grep -c '^agent-queue add --project repo --from human --title repo: 2 notes$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run cat "$NOTES_FIXTURE/queue.stdin"
  assert_line '- cfg/a.json:2-3: raise spawn: to 5'
  assert_line '- cfg/a.json:3: max to 20'
  assert [ ! -f "$("$AR" path)" ]
  assert [ "$(find "$HOME/.agent/requests/repo/sent" -name 'repo-*.md' | wc -l)" -eq 1 ]
}

@test "a failed agent-queue add keeps the draft" {
  two_notes
  touch "$NOTES_FIXTURE/queue.fail"
  run "$AR" send --queue
  assert_failure
  assert [ -f "$("$AR" path)" ]
}

@test "negative control: send with no notes calls neither queue nor panel" {
  run "$AR" send --queue
  assert_failure
  run "$AR" send --session
  assert_failure
  run grep -cE '^agent-(queue|panel) ' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "send --session types one @archive line into the one pane in this repo" {
  two_notes
  { pane_row "$REPO" hub/%7; pane_row /elsewhere hub/%9; } > "$NOTES_FIXTURE/agent-panel.list"
  run "$AR" send --session
  assert_success
  run grep '^agent-panel send --pane hub/%7 ' "$NOTES_FIXTURE/calls.log"
  assert_output --regexp "@$HOME/.agent/requests/repo/sent/repo-[0-9-]+\.md"
  assert [ ! -f "$("$AR" path)" ]
}

@test "send --session refuses zero or two matching panes and never types" {
  two_notes
  pane_row /elsewhere hub/%9 > "$NOTES_FIXTURE/agent-panel.list"
  run "$AR" send --session
  assert_equal "$status" 2
  { pane_row "$REPO" hub/%7; pane_row "$REPO/cfg" hub/%8; } > "$NOTES_FIXTURE/agent-panel.list"
  run --separate-stderr "$AR" send --session
  assert_equal "$status" 2
  assert_line --partial 'hub/%7'
  assert_line --partial 'hub/%8'
  run grep -c '^agent-panel send' "$NOTES_FIXTURE/calls.log"
  assert_output 0
  assert [ -f "$("$AR" path)" ]
}

@test "send --session waits out a session in a dialog" {
  two_notes
  pane_row "$REPO" hub/%7 waiting > "$NOTES_FIXTURE/agent-panel.list"
  run "$AR" send --session
  assert_equal "$status" 2
  run grep -c '^agent-panel send' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "--pane picks the session; an untaken Enter exits 3" {
  two_notes
  touch "$NOTES_FIXTURE/agent-panel.unsent"
  run "$AR" send --session --pane hub/%8
  assert_equal "$status" 3
  run grep -c '^agent-panel send --pane hub/%8 ' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

# The nvim front end, headless, against the real CLI and the agent-queue stub above.
# Call need_nvim before `run nvim_run`: a skip inside `run` ends only its subshell.
need_nvim() { command -v nvim >/dev/null || skip "nvim not installed"; }
nvim_run() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/t.lua"
  nvim --headless -u NONE -i NONE \
    --cmd "set rtp^=$REPO_ROOT/.config/nvim" "$REPO/cfg/a.json" \
    -c "luafile $BATS_TEST_TMPDIR/t.lua" -c 'qa!' 2>&1
}

@test "nvim: <leader>ia's add notes the cursor line, list fills quickfix, send queues it" {
  need_nvim
  run nvim_run '
local ar = require("kennethblack.agent_request")
vim.ui.input = function(opts, cb) cb(opts.default or "bump spawn rate") end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
ar.add()
ar.list()
local qf = vim.fn.getqflist()
io.stdout:write(("\nqf %d %d %s\n"):format(#qf, qf[1].lnum, qf[1].text))
ar.send_queue()
'
  assert_success
  assert_line 'qf 1 2 bump spawn rate'
  run grep -c '^agent-queue add --project repo --from human --title repo: 1 notes$' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run cat "$NOTES_FIXTURE/queue.stdin"
  assert_line '- cfg/a.json:2: bump spawn rate'
}

@test "nvim: a visual selection notes its line range" {
  need_nvim
  run nvim_run '
local ar = require("kennethblack.agent_request")
vim.ui.input = function(_, cb) cb("both lines") end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("normal! Vj")
ar.add()
'
  assert_success
  run "$AR" list --json --dir "$REPO"
  assert_equal "$(jq -r '.[0] | "\(.line)-\(.end)"' <<< "$output")" 2-3
}
