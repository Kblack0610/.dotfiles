#!/usr/bin/env bats
# Every Hyprland chord carries a description (bindd, bindpd, ...): the description is the key's
# row in `keys` (Super+A k), the one list of what each key does. A chord made of several binds
# (a leader leaf: the action, the hint close, the submap reset) needs one described bind, which
# speaks for it. Read from the files as text, so no Hyprland is involved.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  CONFS=("$REPO_ROOT/.config/hypr/conf.d/keybindings.conf" "$REPO_ROOT/.config/hypr/conf.d/leader.conf")
}

# Every chord as "<file>: <submap> <mods>,<key>", with " described" when one of its binds is.
chords() {
  awk '
    FNR == 1 { submap = "reset"; f = FILENAME; sub(/.*\//, "", f) }
    /^[[:space:]]*submap[[:space:]]*=/ { submap = $0; sub(/^[^=]*=[[:space:]]*/, "", submap); sub(/[[:space:]].*/, "", submap) }
    /^[[:space:]]*bind[a-z]*[[:space:]]*=/ {
      flags = $0; sub(/^[[:space:]]*bind/, "", flags); sub(/[[:space:]]*=.*/, "", flags)
      rest = $0; sub(/^[^=]*=[[:space:]]*/, "", rest)
      n = split(rest, a, ","); mods = a[1]; key = a[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", mods); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      c = f ": " submap " " mods "," key
      if (!(c in seen)) { seen[c] = 1; order[++m] = c }
      if (flags ~ /d/) described[c] = 1
    }
    END { for (i = 1; i <= m; i++) print order[i] ((order[i] in described) ? " described" : "") }' "${CONFS[@]}"
}

@test "the parser sees plain, leader and passthrough-submap chords" {
  # Guards the guard: a parse that matched nothing would pass the description test by vacuum.
  run chords
  assert_line 'keybindings.conf: reset $mainMod,Q described'
  assert_line 'keybindings.conf: passthru $mainMod,Escape described'
  assert_line 'leader.conf: pinbar ,k described'
  assert_line 'leader.conf: pinbar-keys ,h described'
}

@test "every chord in every submap has a described bind" {
  # The output is the list of chords without one.
  run bash -c "$(declare -f chords); CONFS=($(printf '%q ' "${CONFS[@]}")); chords | grep -v ' described\$'"
  assert_output ''
}
