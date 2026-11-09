#!/usr/bin/env bats
# keys: the sheet of every live key. What these pin: a Hyprland chord is one row, its described
# bind speaking for it; a row with no description has an empty one and keeps its command; tmux is
# read only from a socket that answered list-sessions, so a dead one is never booted; nvim's dump
# is cached until its config changes. hyprctl, tmux and nvim are stubs; nothing live is touched.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  KEYS="$REPO_ROOT/.local/bin/keys"
  export FX="$BATS_TEST_TMPDIR"
  unset TMUX

  # Super+D; the leader entry; a leaf that is three binds on one key (the described exec, the hint
  # close, the submap reset); an Esc back that must not count as the way in; an undescribed bind.
  jq -n '[
    {submap: "", modmask: 64, key: "D", dispatcher: "exec", arg: "wofi --show drun", has_description: true, description: "app launcher"},
    {submap: "", modmask: 64, key: "1", dispatcher: "workspace", arg: "1", has_description: true, description: "workspace 1"},
    {submap: "", modmask: 64, key: "Q", dispatcher: "killactive", arg: "", has_description: false, description: ""},
    {submap: "", modmask: 64, key: "A", dispatcher: "submap", arg: "pinbar", has_description: true, description: "pin leader"},
    {submap: "pinbar", modmask: 0, key: "k", dispatcher: "exec", arg: "pin-hint.sh close", has_description: false, description: ""},
    {submap: "pinbar", modmask: 0, key: "k", dispatcher: "exec", arg: "kitty -e keys", has_description: true, description: "keys sheet"},
    {submap: "pinbar", modmask: 0, key: "k", dispatcher: "submap", arg: "reset", has_description: false, description: ""},
    {submap: "pinbar", modmask: 0, key: "escape", dispatcher: "submap", arg: "reset", has_description: true, description: "exit"}
  ]' > "$FX/binds.json"
  cat > "$SANDBOX/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "binds -j" ] && exec cat "$FX/binds.json"
exit 1
EOF

  # tmux: every call is logged. `-S <sock> list-sessions` succeeds only for a socket named in
  # $FX/live. The binds are a prefix table with one noted and one plain key, a root key, and both
  # copy-mode tables, of which only copy-mode-vi is live (mode-keys vi).
  export TMUX_TMPDIR="$FX/sock"
  mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"
  : > "$FX/live"
  cat > "$SANDBOX/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/tmux.log"
[ "$1" = -S ] && { sock="$2"; shift 2; }
case "$*" in
  list-sessions) grep -qxF "${sock##*/}" "$FX/live" && { echo "s: 1 windows"; exit 0; }; exit 1 ;;
  "show-options -gv mode-keys") echo vi ;;
  list-keys) printf '%s\n' 'bind-key -T prefix K display-popup keys' 'bind-key -T prefix x kill-pane' \
               'bind-key -T root M-h select-pane -L' 'bind-key -T copy-mode-vi v send-keys -X begin-selection' \
               'bind-key -T copy-mode C-Space send-keys -X begin-selection' ;;
  "list-keys -N -P  -T prefix") echo ' K   Every key' ;;
  "list-keys -aN -P  -T prefix") printf '%s\n' ' K   Every key' ' x   kill-pane' ;;
  "list-keys -N -P  -T root") ;;
  "list-keys -aN -P  -T root") echo ' M-h   select-pane -L' ;;
  "list-keys -N -P  -T copy-mode-vi") echo ' v   Begin a selection' ;;
  "list-keys -aN -P  -T copy-mode-vi") echo ' v   Begin a selection' ;;
  "list-keys -T prefix -- K") echo 'bind-key -T prefix K display-popup keys' ;;
  *) echo "unexpected tmux call: $*" >&2; exit 1 ;;
esac
EOF

  # nvim: logs each run and prints one mapping row, as the headless dump does.
  export XDG_CONFIG_HOME="$FX/config" XDG_CACHE_HOME="$FX/cache"
  mkdir -p "$XDG_CONFIG_HOME/nvim"
  echo 'vim.g.mapleader = " "' > "$XDG_CONFIG_HOME/nvim/init.lua"
  cat > "$SANDBOX/bin/nvim" <<'EOF'
#!/usr/bin/env bash
echo run >> "$FX/nvim.log"
printf 'nvim\tn\t<leader>ff\tFind files\t<Lua function>\n'
EOF
  chmod +x "$SANDBOX/bin/hyprctl" "$SANDBOX/bin/tmux" "$SANDBOX/bin/nvim"
}

# live_socket <name> -- a real socket file in the tmux dir, answering list-sessions.
live_socket() {
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMUX_TMPDIR/tmux-$(id -u)/$1"
  echo "$1" >> "$FX/live"
}

@test "a Hyprland chord is one row, its described bind speaking for it, walked through the submap" {
  run "$KEYS" --print
  assert_success
  assert_line $'hypr\t\tSuper+D\tapp launcher\texec wofi --show drun'
  assert_line $'hypr\t\tSuper+Q\t\tkillactive'
  assert_line $'hypr\t\tSuper+A k\tkeys sheet\texec kitty -e keys'
  assert_line $'hypr\t\tSuper+A escape\texit\tsubmap reset'
  assert_equal "$(grep -c $'^hypr\t\tSuper+A k\t' <<<"$output")" 1
}

@test "a tmux row is the bind's note, or empty with its command when it has none; only the live copy table" {
  live_socket hub
  run "$KEYS" --print
  assert_success
  assert_line $'tmux\tprefix\tPrefix K\tEvery key\t'
  assert_line $'tmux\tprefix\tPrefix x\t\tkill-pane'
  assert_line $'tmux\troot\tM-h\t\tselect-pane -L'
  assert_line $'tmux\tcopy-mode-vi\tcopy-mode-vi: v\tBegin a selection\t'
  refute_output --partial 'C-Space'
}

@test "with no live tmux server the layer says so, and no list-keys ever runs" {
  # A socket file that does not answer: list-keys on it would boot a server.
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TMUX_TMPDIR/tmux-$(id -u)/hub"
  run "$KEYS" --print
  assert_success
  assert_line --regexp $'^tmux\t\t-\tno tmux server is running'
  run grep -c 'list-keys' "$FX/tmux.log"
  assert_output 0
}

@test "hub is read first when several worlds are live" {
  live_socket alpha
  live_socket hub
  run "$KEYS" --print
  assert_success
  run grep -m1 'list-keys' "$FX/tmux.log"
  assert_output --regexp "^-S .*/hub list-keys"
}

@test "nvim is dumped once and cached until a file under its config changes" {
  "$KEYS" --print >/dev/null
  run "$KEYS" --print
  assert_line $'nvim\tn\t<leader>ff\tFind files\t<Lua function>'
  assert_equal "$(wc -l < "$FX/nvim.log")" 1
  touch -d '+1 minute' "$XDG_CONFIG_HOME/nvim/init.lua"
  "$KEYS" --print >/dev/null
  assert_equal "$(wc -l < "$FX/nvim.log")" 2
}

@test "a noted tmux row's preview asks tmux for the bind's command" {
  live_socket hub
  run "$KEYS" preview tmux prefix 'Prefix K' ''
  assert_success
  assert_line 'bind-key -T prefix K display-popup keys'
}

@test "--md is one table, pipes in a description escaped" {
  jq '.[0].description = "a | b"' "$FX/binds.json" > "$FX/b2" && mv "$FX/b2" "$FX/binds.json"
  run "$KEYS" --md
  assert_success
  assert_line '| Layer | Key | What it does |'
  assert_line '| hypr | `Super+D` | a \| b |'
}

@test "a tab lists one layer's described keys; all tags each row with its layer" {
  live_socket hub
  export NO_COLOR=1
  run "$KEYS" _list tmux
  assert_success
  assert_line --regexp $'^tmux\tprefix\tPrefix K\t.*Every key\t$'
  refute_output --partial 'kill-pane'
  refute_output --partial 'hypr'
  run "$KEYS" _list all
  assert_line --regexp $'^hypr\t\tSuper\\+D\thypr +Super\\+D +app launcher\t'
  assert_line --regexp $'^nvim\tn\t<leader>ff\tnvim +n <leader>ff .*Find files\t'
  assert_line --regexp $'^hypr\t\tSuper\\+1\thypr +Super\\+1 +workspace 1\tworkspace 1$'
  refute_output --partial 'killactive'
}

@test "--md shows a bind with no description by its command" {
  run "$KEYS" --md
  assert_line '| hypr | `Super+Q` | killactive |'
}

@test "tab steps to the next layer and wraps; shift-tab steps back" {
  FZF_PROMPT='nvim > ' run "$KEYS" _switch next
  assert_output --regexp '^change-prompt~all > ~.*reload~.*keys _list all~\+first$'
  FZF_PROMPT='all > ' run "$KEYS" _switch prev
  assert_output --regexp '^change-prompt~nvim > ~'
  FZF_PROMPT='hypr > ' run "$KEYS" _switch next
  assert_output --regexp '\[ tmux \]'
}

@test "an unknown layer is refused before fzf starts" {
  run "$KEYS" vim
  assert_failure 2
  assert_output --partial "no layer 'vim'"
}
