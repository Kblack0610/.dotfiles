#!/usr/bin/env bats
# desk: the state file picks each slot's part, `use` refuses what it does not know and
# leaves the state alone, `signal` reads the chip's number from the real config.base, and
# nothing touches a real bar, notifier or systemd (stubs log every call).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DESK="$REPO_ROOT/.local/bin/desk"
  STATE="$HOME/.local/state/desk/parts"
  export FX="$BATS_TEST_TMPDIR"
  for b in pkill dunstctl waybar dunst; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$FX/calls.log"\n' "$b" > "$SANDBOX/bin/$b"
    chmod +x "$SANDBOX/bin/$b"
  done
}

@test "no state file: each slot runs its first part" {
  run "$DESK" current
  assert_success
  assert_output $'bar=waybar-classic\nnotify=dunst'
}

@test "use records the part and restarts its unit" {
  run "$DESK" use bar waybar-classic
  assert_success
  assert_equal "$(cat "$STATE")" "bar=waybar-classic"
  run grep -x 'systemctl --user restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_success
}

@test "use refuses an unknown part and leaves the state alone" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-classic" > "$STATE"
  run "$DESK" use bar bogus
  assert_failure 2
  assert_output --partial "'bogus' is not a bar part"
  assert_equal "$(cat "$STATE")" "bar=waybar-classic"
  run grep -c restart "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "use refuses a part whose binary is missing" {
  # A PATH with the tools desk needs and no dunst, real or stub.
  local only="$BATS_TEST_TMPDIR/only" t
  mkdir -p "$only"
  for t in bash env awk grep mkdir mv dirname readlink cat xargs sort head; do ln -s "$(command -v "$t")" "$only/$t"; done
  PATH="$only" run "$DESK" use notify dunst
  assert_failure 1
  assert_output --partial "needs dunst"
  [ ! -e "$STATE" ]
}

@test "a part this checkout no longer knows falls back to the default" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=retired-bar" > "$STATE"
  run "$DESK" get bar
  assert_output waybar-classic
}

@test "start starts every slot's unit" {
  run "$DESK" start
  assert_success
  run grep -c -x -e 'systemctl --user start waybar.service' -e 'systemctl --user start dunst.service' "$NOTES_FIXTURE/calls.log"
  assert_output 2
}

@test "signal reads each chip's number from config.base and the pin config" {
  run "$DESK" signal custom/gungan custom/passthrough custom/machines custom/ci
  assert_success
  run cat "$FX/calls.log"
  assert_output $'pkill -RTMIN+9 -x waybar\npkill -RTMIN+10 -x waybar\npkill -RTMIN+11 -x waybar'
}

@test "signal on a chip with no signal key exits 2 and signals nothing" {
  run "$DESK" signal custom/nonexistent
  assert_failure 2
  [ ! -e "$FX/calls.log" ]
}

@test "notify maps each verb to the running notifier" {
  for v in close close-all history dnd; do "$DESK" notify "$v"; done
  run cat "$FX/calls.log"
  assert_output $'dunstctl close\ndunstctl close-all\ndunstctl history-pop\ndunstctl set-paused toggle'
  run "$DESK" notify bogus
  assert_failure 2
}

@test "a restart that fails puts the old choice back and exits 1" {
  mkdir -p "$(dirname "$STATE")" && printf 'bar=waybar-classic\nnotify=dunst\n' > "$STATE"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/systemctl"
  run "$DESK" use bar waybar-classic
  assert_failure 1
  assert_output --partial "did not start"
  assert_equal "$(cat "$STATE")" $'bar=waybar-classic\nnotify=dunst'
}

@test "start exits non-zero when a unit fails, so desk.service shows failed" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/systemctl"
  run "$DESK" start
  assert_failure
  assert_output --partial "bar did not start"
}

@test "signal still signals the known chips when one id has no number" {
  run "$DESK" signal custom/nonexistent custom/gungan
  assert_failure 2
  assert_output --partial "no signal for 'custom/nonexistent'"
  run cat "$FX/calls.log"
  assert_output 'pkill -RTMIN+9 -x waybar'
}

@test "notify under swaync maps each verb to swaync-client" {
  printf '#!/usr/bin/env bash\necho "swaync-client $*" >> "$FX/calls.log"\n' > "$SANDBOX/bin/swaync-client"
  chmod +x "$SANDBOX/bin/swaync-client"
  mkdir -p "$(dirname "$STATE")" && echo "notify=swaync" > "$STATE"
  for v in close close-all history dnd; do "$DESK" notify "$v"; done
  run cat "$FX/calls.log"
  assert_output $'swaync-client --hide-latest\nswaync-client --hide-all\nswaync-client -t -sw\nswaync-client -d -sw'
}

@test "switching the notifier restarts the bar, so its notify chip rebinds" {
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/swaync" && chmod +x "$SANDBOX/bin/swaync"
  run "$DESK" use notify swaync
  assert_success
  run grep -x -e 'systemctl --user restart swaync.service' -e 'systemctl --user restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_output $'systemctl --user restart swaync.service\nsystemctl --user restart waybar.service'
  # Choosing the notifier already running leaves the bar alone.
  : > "$NOTES_FIXTURE/calls.log"
  run "$DESK" use notify swaync
  assert_success
  run grep -c 'restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "waybar-modern signals waybar the same way as classic" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-modern" > "$STATE"
  run "$DESK" signal custom/gungan
  assert_success
  run cat "$FX/calls.log"
  assert_output 'pkill -RTMIN+9 -x waybar'
}

@test "launch.sh gives waybar the stylesheet of the bar part desk records" {
  mkdir -p "$HOME/.local/bin" && ln -s "$REPO_ROOT/.local/bin/desk" "$HOME/.local/bin/desk"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR" WAYBAR_BIN="$SANDBOX/bin/waybar"
  run "$REPO_ROOT/.config/waybar/launch.sh"
  assert_success
  mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-modern" > "$STATE"
  run "$REPO_ROOT/.config/waybar/launch.sh"
  assert_success
  run grep -o -e '-s .*' "$FX/calls.log"
  assert_output $'-s '"$BATS_TEST_TMPDIR"$'/waybar/style.css\n-s '"$BATS_TEST_TMPDIR"$'/waybar/style-modern.css'
}

@test "style-modern.css layers palette and modern layout after the theme" {
  run grep '^@import' "$REPO_ROOT/.config/waybar/style-modern.css"
  assert_output $'@import url("style.css");\n@import url("palette.css");\n@import url("layout-modern.css");'
}

@test "noctalia is a bar part, run by its own unit" {
  run "$DESK" parts bar
  assert_output --partial 'bar noctalia noctalia.service'
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/noctalia" && chmod +x "$SANDBOX/bin/noctalia"
  run "$DESK" use bar noctalia
  assert_success
  run grep -x 'systemctl --user restart noctalia.service' "$NOTES_FIXTURE/calls.log"
  assert_success
  # A notifier switch under noctalia restarts noctalia, never waybar.
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/swaync" && chmod +x "$SANDBOX/bin/swaync"
  : > "$NOTES_FIXTURE/calls.log"
  run "$DESK" use notify swaync
  run grep -c -e 'restart noctalia.service' -e 'restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c 'restart noctalia.service' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "signal under noctalia sends each number once over the plugin IPC, no pkill" {
  printf '#!/usr/bin/env bash\necho "noctalia $*" >> "$FX/calls.log"\n' > "$SANDBOX/bin/noctalia" && chmod +x "$SANDBOX/bin/noctalia"
  mkdir -p "$(dirname "$STATE")" && echo "bar=noctalia" > "$STATE"
  run "$DESK" signal custom/gungan custom/ci custom/passthrough custom/gungan
  assert_success
  run cat "$FX/calls.log"
  assert_output $'noctalia msg plugin dotfiles/chips:chip all refresh 9\nnoctalia msg plugin dotfiles/chips:chip all refresh 10\nnoctalia msg plugin dotfiles/chips:chip all refresh 11'
}

# A config.base with a chip per way one runs (poll, once, stream, gated), plus format
# icons, an empty exec and a stream that ends, for `desk chip`.
chip_fixture() {
  export DESK_WAYBAR_DIR="$BATS_TEST_TMPDIR/waybar"
  mkdir -p "$DESK_WAYBAR_DIR"
  cat > "$DESK_WAYBAR_DIR/config.base" <<'JSON'
{
    // a comment line, as the real config.base has
    "custom/poll": { "exec": "printf '{\"text\":\"<b>ci</b> &amp; ok\",\"tooltip\":\"<span>2 down</span>\",\"class\":[\"warn\",\"x\"]}\\n'", "interval": 60, "signal": 10, "on-click": "hub --tab ci", "on-click-middle": "hub --tab runners" },
    "custom/once": { "exec": "echo plain text", "interval": "once", "signal": 9 },
    "custom/stream": { "exec": "printf 'a\\nb\\n'", "return-type": "json" },
    "custom/gated": { "exec": "echo shown", "exec-if": "false" },
    "custom/icon": { "exec": "printf '{\"text\":\"3\",\"alt\":\"dnd\"}\\n{\"text\":\"4\"}\\n'", "format": "{icon} {}", "format-icons": { "dnd": "D", "default": "N" } },
    "custom/blank": { "exec": "true" },
    "custom/again": { "exec": "echo tick", "restart-interval": 0 },
    "bluetooth": { "format": "x" }
}
JSON
}

@test "chip prints how each module runs: poll, once or stream" {
  chip_fixture
  run "$DESK" chip custom/poll
  assert_output '{"mode":"poll","interval":60,"signal":10,"click":"hub --tab ci","right_click":"","middle_click":"hub --tab runners"}'
  run "$DESK" chip custom/once
  assert_output --partial '"mode":"once"'
  run "$DESK" chip custom/stream
  assert_output --partial '"mode":"stream"'
}

@test "chip run prints plain JSON: no pango, entities decoded, the first class" {
  chip_fixture
  run "$DESK" chip custom/poll run
  assert_success
  assert_output '{"text":"ci & ok","tooltip":"2 down","class":"warn"}'
  run "$DESK" chip custom/once run
  assert_output '{"text":"plain text","tooltip":"","class":""}'
  run "$DESK" chip custom/stream run
  assert_output $'{"text":"a","tooltip":"","class":""}\n{"text":"b","tooltip":"","class":""}'
}

@test "chip run on a failing exec-if prints an empty chip and never runs the exec" {
  chip_fixture
  run "$DESK" chip custom/gated run
  assert_success
  assert_output '{"text":"","tooltip":"","class":""}'
}

@test "chip run applies the module's format, {icon} by alt and else the default icon" {
  chip_fixture
  run "$DESK" chip custom/icon run
  assert_success
  assert_output $'{"text":"D 3","tooltip":"","class":""}\n{"text":"N 4","tooltip":"","class":""}'
}

@test "chip run on an exec that prints nothing prints nothing, which hides the chip" {
  chip_fixture
  run "$DESK" chip custom/blank run
  assert_success
  assert_output ''
}

@test "chip stream runs the exec again when it ends, and exits 0 once the reader closes" {
  chip_fixture
  # One line per run, so three lines are two restarts. timeout is the hang guard: a
  # stream that never noticed the closed pipe would end 124, not 0.
  run bash -c "set -o pipefail; timeout 10 '$DESK' chip custom/again stream | head -n 3"
  assert_success
  assert_output $'{"text":"tick","tooltip":"","class":""}\n{"text":"tick","tooltip":"","class":""}\n{"text":"tick","tooltip":"","class":""}'
}

@test "chip exits 2 on an unknown module and on one with no exec" {
  chip_fixture
  run "$DESK" chip custom/nope
  assert_failure 2
  assert_output --partial "no module 'custom/nope'"
  run "$DESK" chip bluetooth run
  assert_failure 2
  assert_output --partial "has no exec"
}

@test "every chip in noctalia's config.toml is a module desk can run" {
  local id
  for id in $(grep -o 'module = "[^"]*"' "$REPO_ROOT/.config/noctalia/config.toml" | cut -d'"' -f2); do
    run "$DESK" chip "$id"
    assert_success
  done
}

@test "the chips plugin manifest parses and every key it names is translated" {
  local dir="$REPO_ROOT/.local/share/noctalia/plugins/dotfiles-chips" key
  run python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$dir/plugin.toml"
  assert_success
  for key in $(grep -oE '(label|description)_key = "[^"]+"' "$dir/plugin.toml" | cut -d'"' -f2); do
    run jq -e --arg k "$key" 'getpath($k | split(".")) // .[$k] | strings' "$dir/translations/en.json"
    assert_success
  done
}

@test "every Super+A d leaf runs desk use for the part it names, and every part has a leaf" {
  load '../helpers/hypr'
  local leaves parts
  # Each leaf as "<slot> <part>" from the command it runs, kept only when its label says the same.
  leaves="$(hypr_dump registry | jq -r '.[] | select(.submap == "pinbar-desk" and (.arg | test("desk use")))
    | (.arg | capture("desk use (?<s>[^ ]+) (?<p>[^ )]+)")) as $c
    | select(.description == "\($c.s): \($c.p)") | "\($c.s) \($c.p)"' | sort)"
  parts="$("$DESK" parts | awk '{ print $1, $2 }' | sort)"
  [ -n "$leaves" ]
  assert_equal "$leaves" "$parts"
}

@test "every widget noctalia's config.toml defines sits in a lane or a pod" {
  # A widget left out of every lane and capsule_group never draws, and nothing else says so.
  run python3 -c '
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
bar = c["bar"]["default"]
placed = {w for lane in ("start", "center", "end") for w in bar.get(lane, []) if not w.startswith("group:")}
placed |= {m for g in bar.get("capsule_group", []) for m in g["members"]}
missing = sorted(set(c["widget"]) - placed)
print("not on the bar:", *missing) if missing else None
sys.exit(1 if missing else 0)
' "$REPO_ROOT/.config/noctalia/config.toml"
  assert_success
}
