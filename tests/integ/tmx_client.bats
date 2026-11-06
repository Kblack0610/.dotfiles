#!/usr/bin/env bats
# tmx from the desktop: with no $TMUX and no terminal of its own (a Hyprland key, a waybar
# click), a hop drives the terminal you typed in last instead of attaching where it stands;
# `tmx client` names that terminal and `tmx popup` shows a command on it. Recording tmux stub;
# sockets are real files so panel_live_servers sees the worlds; kitty, setsid, hyprctl stubbed.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  TMX="$REPO_ROOT/.local/src/tmux/servers.sh"
  export TMUX_SERVERS_DIR="$SANDBOX/manifests"
  mkdir -p "$TMUX_SERVERS_DIR"
  printf 'hub ~\n' > "$TMUX_SERVERS_DIR/hub.conf"
  printf 'lab ~\n' > "$TMUX_SERVERS_DIR/lab.conf"
  unset TMUX

  # Short path: a unix socket path is capped near 104 bytes on macOS.
  export TMUX_TMPDIR; TMUX_TMPDIR="$(mktemp -d /tmp/tmxc.XXXXXX)"
  local d="$TMUX_TMPDIR/tmux-$(id -u)" n
  mkdir -p "$d"
  for n in hub lab; do
    python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$d/$n"
  done

  for n in kitty setsid hyprctl; do
    cat > "$SANDBOX/bin/$n" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$NOTES_FIXTURE/calls.log"
[ "${0##*/} $1" = "hyprctl clients" ] && cat "$NOTES_FIXTURE/hypr.clients" 2>/dev/null
exit 0
EOF
    chmod +x "$SANDBOX/bin/$n"
  done
}

teardown() { [ -n "${TMUX_TMPDIR:-}" ] && rm -rf "$TMUX_TMPDIR"; return 0; }

# client <server> <activity> <name> <pid> -- a terminal attached to that world.
client() { printf '%s %s %s %s\n' "$2" "$1" "$3" "$4" >> "$NOTES_FIXTURE/tmux.clients.$1"; }

@test "tmx client names the terminal typed in last, across worlds" {
  client hub 100 /dev/pts/1 11
  client lab 300 /dev/pts/5 55
  client hub 200 /dev/pts/2 22
  run "$TMX" client
  assert_success
  assert_output 'lab /dev/pts/5'
}

@test "tmx client with no terminal attached anywhere says so and fails" {
  run "$TMX" client
  assert_failure
  assert_output --partial 'no tmux client is attached'
}

@test "goto with no tty hops that terminal in place: no attach here, no new window" {
  client hub 100 /dev/pts/1 11
  client lab 300 /dev/pts/5 55
  run "$TMX" goto lab work < /dev/null
  assert_success
  assert_called "tmux -L lab detach-client -t /dev/pts/5 -E $TMX land lab work"
  assert_not_called 'attach'
  assert_not_called 'kitty'
}

@test "with a tty it attaches right here, as a shell in a fresh terminal expects" {
  # Negative control for the branch above: the same call from a terminal never drives another.
  client lab 300 /dev/pts/5 55
  : > "$NOTES_FIXTURE/tmux.sessions.lab"; echo work >> "$NOTES_FIXTURE/tmux.sessions.lab"
  run script -qec "$(printf '%q ' "$TMX" goto lab work)" /dev/null
  assert_not_called 'detach-client'
  assert_called 'tmux -L lab attach -t =work'
}

@test "on Hyprland the terminal whose process holds the client gets focus" {
  # The client runs under the terminal's shell, so the window's pid is an ancestor of it.
  sleep 300 & local child=$!
  client lab 300 /dev/pts/5 "$child"
  printf '[{"pid": 1}, {"pid": %s}]\n' "$$" > "$NOTES_FIXTURE/hypr.clients"
  HYPRLAND_INSTANCE_SIGNATURE=test run "$TMX" hop lab < /dev/null
  kill "$child"
  assert_success
  assert_called "hyprctl dispatch focuswindow pid:$$"
}

@test "off Hyprland nothing asks the compositor" {
  client lab 300 /dev/pts/5 55
  run "$TMX" hop lab < /dev/null
  assert_success
  assert_not_called 'hyprctl'
}

@test "with no terminal attached anywhere a new one opens on the destination" {
  WAYLAND_DISPLAY=wayland-1 run "$TMX" goto lab work < /dev/null
  assert_success
  assert_called "setsid -f kitty -e $TMX land lab work"
}

@test "tmx popup shows the command on the terminal typed in last and focuses it" {
  sleep 300 & local child=$!
  client hub 100 /dev/pts/1 11
  client lab 300 /dev/pts/5 "$child"
  printf '[{"pid": %s}]\n' "$$" > "$NOTES_FIXTURE/hypr.clients"
  HYPRLAND_INSTANCE_SIGNATURE=test run "$TMX" popup agent-notify pick
  kill "$child"
  assert_success
  assert_called 'tmux -L lab display-popup -c /dev/pts/5 -E -w 95% -h 95% agent-notify pick'
  assert_called "hyprctl dispatch focuswindow pid:$$"
  assert_not_called 'kitty'
}

@test "tmx popup with no terminal attached opens one floating kitty, and fails with no display" {
  WAYLAND_DISPLAY=wayland-1 run "$TMX" popup agent-panel
  assert_success
  assert_called 'setsid -f kitty --class floating-term -e agent-panel'
  : > "$NOTES_FIXTURE/calls.log"
  run "$TMX" popup agent-panel
  assert_failure
  assert_output --partial 'no display'
  assert_not_called 'kitty'
}
