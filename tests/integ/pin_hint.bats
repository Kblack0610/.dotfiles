#!/usr/bin/env bats
# pin-hint.sh: the leader's which-key popup is the submap's described binds, read from
# `hyprctl binds -j`, so leader.conf is the only list of leader keys. What these pin: an
# undescribed bind never shows; keys sharing a description share an entry; a submap with no
# described binds says so instead of an empty popup; and every key in the real leader.conf's
# submaps has exactly one described bind, so a leaf added without one fails here.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  HINT="$REPO_ROOT/.config/waybar/pin-hint.sh"
  export FX="$BATS_TEST_TMPDIR"
  cat > "$SANDBOX/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "binds -j" ] && exec cat "$FX/binds.json"
exit 1
EOF
  # dunstify: the popup's title and body, one argument per line, never the real desktop.
  cat > "$SANDBOX/bin/dunstify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FX/shown"
EOF
  chmod +x "$SANDBOX/bin/hyprctl" "$SANDBOX/bin/dunstify"
  jq -n '[
    {submap: "", key: "A", dispatcher: "submap", arg: "pinbar", has_description: true, description: "pin leader"},
    {submap: "pinbar", key: "space", dispatcher: "exec", arg: "control-menu", has_description: true, description: "control menu"},
    {submap: "pinbar", key: "a", dispatcher: "exec", arg: "agent-panel", has_description: true, description: "agent panel"},
    {submap: "pinbar", key: "a", dispatcher: "exec", arg: "pin-hint.sh close", has_description: false, description: ""},
    {submap: "pinbar", key: "u", dispatcher: "submap", arg: "pinbar-utils", has_description: true, description: "utils >"},
    {submap: "pinbar", key: "escape", dispatcher: "submap", arg: "reset", has_description: true, description: "exit"},
    {submap: "pinbar", key: "q", dispatcher: "submap", arg: "reset", has_description: true, description: "exit"},
    {submap: "pinbar-git", key: "s", dispatcher: "exec", arg: "git status", has_description: true, description: "dotfiles git status"}
  ]' > "$FX/binds.json"
}

# dunstify -r ID -t MS -u low TITLE BODY: the title is argument 7, the body the rest.
title() { sed -n 7p "$FX/shown"; }
body() { sed -n '8,$p' "$FX/shown"; }

@test "the main popup is pinbar's described binds, two to a line, esc and q sharing 'exit'" {
  run "$HINT" main
  assert_success
  assert_equal "$(title)" " pin leader"
  assert_equal "$(body)" "space control menu      a agent panel
u utils >               esc/q exit"
  refute_output --partial "pin-hint.sh close"
}

@test "a sub-level reads its own submap and title" {
  run "$HINT" git
  assert_success
  assert_equal "$(title)" " pin / git"
  assert_equal "$(body)" "s dotfiles git status"
}

@test "a submap with no described binds says so, not a blank popup" {
  run "$HINT" sync
  assert_success
  assert_equal "$(body)" "no described binds in submap pinbar-sync (hyprctl binds -j)"
  run "$HINT" nope
  assert_failure 2
}

# undescribed <leader.conf>: each submap key whose described-bind count is not exactly one.
undescribed() {
  awk '
    /^submap = / { sm = $3; next }
    sm != "" && sm != "reset" && /^bindp?d? = / {
      split($0, p, ","); k = sm " " p[2]; n[k] += 0; if ($1 ~ /d$/) n[k]++
    }
    END { for (k in n) if (n[k] != 1) { print k ": " n[k] " described"; bad = 1 } exit bad }
  ' "$1"
}

@test "every key in the real leader.conf submaps has exactly one described bind" {
  run undescribed "$REPO_ROOT/.config/hypr/conf.d/leader.conf"
  assert_success
  # The same check fails a leaf with no description.
  sed '0,/^bindpd = ,a, agent panel,/s//bindp = ,a,/' "$REPO_ROOT/.config/hypr/conf.d/leader.conf" > "$FX/leader.conf"
  run undescribed "$FX/leader.conf"
  assert_failure
  assert_output "pinbar-agents a: 0 described"
}
