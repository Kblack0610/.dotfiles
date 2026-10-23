#!/usr/bin/env bats
# storage.sh -- the disk overview behind the waybar tooltip and the storage picker.
#
# The machine is faked at the three commands storage reads it through: lsblk (a fixture
# JSON), findmnt (which filesystem a path is on, mount options, network mounts) and df (root
# and network usage). du runs for real, on small trees inside the sandbox, so the scan is
# exercised end to end without touching a real drive.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  STORAGE="$REPO_ROOT/.local/src/system/storage.sh"
  export STORAGE
  export STORAGE_BUCKETS="$SANDBOX/buckets"
  export STORAGE_CACHE="$SANDBOX/cache"
  export STORAGE_NET_TIMEOUT=1
  # Anything under here is "on the data drive"; everything else is on the root drive.
  export FAKE_DATA="$SANDBOX/mnt-data"
  export FAKE_LSBLK="$SANDBOX/lsblk.json"
  mkdir -p "$FAKE_DATA"

  # Root drive: btrfs, one partition mounted at / and /home, plus an EFI partition that
  # must not show. Data drive: ext4, mounted twice at the same place, read-only. A blank
  # disk, a disk with an unmounted partition, and zram, which must not show either. The
  # root model carries an & so the pango escaping is exercised.
  cat >"$FAKE_LSBLK" <<'JSON'
{"blockdevices": [
 {"name": "zram0", "model": null, "size": 100, "type": "disk", "fstype": "swap", "mountpoints": ["[SWAP]"]},
 {"name": "nvme9n1", "model": "Fast & Big  ", "size": 2000000000000, "type": "disk", "fstype": null, "mountpoints": [null],
  "children": [
   {"name": "efi9", "size": 314572800, "type": "part", "fstype": "vfat", "mountpoints": ["/boot/efi"], "fssize": 314572800, "fsused": 1000, "fsavail": 314571800},
   {"name": "fakeroot", "size": 1999000000000, "type": "part", "fstype": "btrfs", "mountpoints": ["/home", "/"], "fssize": 1999000000000, "fsused": 1800000000000, "fsavail": 199000000000}
  ]},
 {"name": "nvme8n1", "model": "Roomy", "size": 1000000000000, "type": "disk", "fstype": null, "mountpoints": [null],
  "children": [
   {"name": "fakedata", "size": 1000000000000, "type": "part", "fstype": "ext4", "mountpoints": ["/mnt/data", "/mnt/data"], "fssize": 1000000000000, "fsused": 300000000000, "fsavail": 700000000000}
  ]},
 {"name": "sdz", "model": "Blank", "size": 256000000000, "type": "disk", "fstype": null, "mountpoints": [null]},
 {"name": "nvme7n1", "model": "Old", "size": 500000000000, "type": "disk", "fstype": null, "mountpoints": [null],
  "children": [
   {"name": "oldpart", "size": 500000000000, "type": "part", "fstype": "ext4", "mountpoints": [null]}
  ]}
]}
JSON

  cat >"$SANDBOX/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_LSBLK"
EOF

  cat >"$SANDBOX/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
args="$*"
last="${!#}"
case "$args" in
*"-o SOURCE -T"*)
  case "$last" in "$FAKE_DATA"*) echo /dev/fakedata ;; *) echo '/dev/fakeroot[/@home]' ;; esac ;;
*"-o TARGET -T"*)
  case "$last" in "$FAKE_DATA"*) echo /mnt/data ;; *) echo /home ;; esac ;;
*"--mountpoint"*)
  if [ "$last" = /mnt/data ]; then echo ro,relatime; else echo rw,relatime; fi ;;
*"-t "*)
  [ -n "${FAKE_NAS:-}" ] && printf '%s //nas/share\n' "$FAKE_NAS" ;;
esac
exit 0
EOF

  cat >"$SANDBOX/bin/df" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [ "$last" = / ]; then
  printf 'Used Avail\n%s %s\n' "${FAKE_ROOT_USED:-90}" "${FAKE_ROOT_AVAIL:-10}"
else
  # A slow NAS that DOES answer eventually: without the timeout this would be sized.
  [ -n "${FAKE_NAS_HANG:-}" ] && sleep 4
  printf 'Size Used Avail\n%s %s %s\n' 2000000000000 1400000000000 600000000000
fi
EOF

  # wt's dry run names one of the two worktrees it would reap.
  cat >"$SANDBOX/bin/wt" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "gc --dry-run" ] || exit 1
printf 'would reap  wt-a\nkept        wt-b                         dirty\n'
EOF
  chmod +x "$SANDBOX/bin/"{lsblk,findmnt,df,wt}

  mkdir -p "$HOME/trees/wt-a" "$HOME/trees/wt-b" "$HOME/stuff" "$FAKE_DATA/games"
  head -c 3145728 /dev/zero >"$HOME/trees/wt-a/blob"
  head -c 1048576 /dev/zero >"$HOME/trees/wt-b/blob"
  head -c 1048576 /dev/zero >"$HOME/stuff/blob"
  head -c 2097152 /dev/zero >"$FAKE_DATA/games/blob"
  # Steam moved to the data drive, with the old path left as a symlink.
  mkdir -p "$HOME/.local/share"
  ln -s "$FAKE_DATA/games" "$HOME/.local/share/Steam"

  cat >"$STORAGE_BUCKETS" <<'EOF'
# a comment, and a blank line below

worktrees|~/trees|wt gc
stuff|~/stuff|
Steam|~/.local/share/Steam|
not here|~/no-such-dir|
EOF
}

field() { awk -F'\t' -v l="$1" -v f="$2" '$2 == l { print $f }'; }

@test "drives: every disk shows, mounted or not, with zram and EFI left out" {
  run "$STORAGE" overview
  assert_success
  assert_output --partial 'nvme9n1  Fast & Big'
  assert_output --regexp 'nvme8n1 +Roomy .* /mnt/data .* 30%  [0-9]+G free, read-only'
  assert_output --regexp 'sdz +Blank .* no filesystem'
  assert_output --regexp 'nvme7n1 +Old .* not mounted \(ext4\)'
  refute_output --partial 'zram0'
  refute_output --partial '/boot/efi'
  # the data drive is mounted twice at one place and must be listed once
  [ "$(grep -c '/mnt/data  ' <<<"$output")" -eq 1 ] || fail "data drive listed $(grep -c '/mnt/data  ' <<<"$output") times"
}

@test "drives: a btrfs root mounted at several subvolumes reports /" {
  run "$STORAGE" overview
  assert_output --regexp 'nvme9n1 .* /  +[^ ]+ +91%'
}

@test "overview with no cache says to scan instead of showing stale nothing" {
  run "$STORAGE" overview
  assert_success
  assert_output --partial 'No scan yet - run: storage scan'
  refute_output --partial 'Biggest'
}

@test "scan files each bucket under the drive it really lives on and skips absent paths" {
  run "$STORAGE" scan
  assert_success
  run "$STORAGE" --list
  assert_success
  # the symlinked bucket is sized on the data drive, at its real path
  assert_equal "$(field Steam 1 <<<"$output")" "$FAKE_DATA/games"
  assert_regex "$(field Steam 3 <<<"$output")" '^ +[0-9.]+[KM]  Steam +/mnt/data '
  # a bucket with no reclaim command keeps every later column in place
  assert_regex "$(field stuff 3 <<<"$output")" '^ +[0-9.]+[KM]  stuff +/ '
  refute_output --partial 'not here'
  # every mounted drive gets an everything-else row
  assert_equal "$(field other:/mnt/data 1 <<<"$output")" /mnt/data
  assert_equal "$(field other:/ 1 <<<"$output")" /
}

@test "everything else is the drive's used space minus its buckets" {
  "$STORAGE" scan 2>/dev/null
  local buckets
  buckets=$(awk -F'\t' '$4 == "fakeroot" { s += $1 } END { printf "%.0f", s }' "$STORAGE_CACHE/scan.tsv")
  [ "$buckets" -gt 0 ] || fail "no buckets were sized on the root drive"
  run "$STORAGE" preview other:/
  assert_success
  assert_output --partial 'everything else on /'
  run bash -c '"$STORAGE" overview | grep "everything else  *  /$"'
  assert_output --partial "$(numfmt --to=iec $((1800000000000 - buckets)))"
}

@test "worktree reclaim counts only what wt gc would reap" {
  "$STORAGE" scan 2>/dev/null
  # wt-a (3 MiB) is the only reapable one, so the estimate is its size, not the bucket's
  local a total
  a=$(du -B1 -s "$HOME/trees/wt-a" | cut -f1)
  total=$(du -B1 -s "$HOME/trees" | cut -f1)
  [ "$(numfmt --to=iec "$a")" != "$(numfmt --to=iec "$total")" ] || fail "fixture cannot tell part from whole"
  run "$STORAGE" overview
  assert_output --regexp " +$(numfmt --to=iec "$a" | sed 's/\./\\./')  worktrees \(1 reapable\) +wt gc"
}

@test "preview lists a bucket's children biggest first" {
  "$STORAGE" scan 2>/dev/null
  run "$STORAGE" preview worktrees
  assert_success
  assert_output --partial 'ctrl-x runs: wt gc'
  local a b
  a=$(grep -n 'wt-a' <<<"$output" | cut -d: -f1)
  b=$(grep -n 'wt-b' <<<"$output" | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "children not biggest-first: $output"
}

@test "waybar: valid JSON, critical at 90 percent" {
  "$STORAGE" scan 2>/dev/null
  FAKE_ROOT_USED=90 FAKE_ROOT_AVAIL=10 run "$STORAGE" waybar
  assert_success
  jq -e '.class == "critical" and .percentage == 90 and (.text | startswith("90% "))' <<<"$output" ||
    fail "not critical at 90: $output"
}

@test "waybar: not critical at 89 percent" {
  FAKE_ROOT_USED=89 FAKE_ROOT_AVAIL=11 run "$STORAGE" waybar
  assert_success
  jq -e '.class == "" and .percentage == 89' <<<"$output" || fail "wrong class at 89: $output"
}

@test "waybar: the tooltip is escaped pango markup" {
  "$STORAGE" scan 2>/dev/null
  run "$STORAGE" waybar
  local tip
  tip=$(jq -r .tooltip <<<"$output")
  assert_regex "$tip" '^<tt>'
  assert_regex "$tip" 'Fast &amp; Big'
  refute_regex "$tip" 'Fast & Big'
  assert_regex "$tip" '<b>Biggest</b>'
}

@test "a network mount that does not answer is reported, not waited on" {
  FAKE_NAS=/mnt/nas FAKE_NAS_HANG=1 run "$STORAGE" overview
  assert_success
  assert_output --regexp '//nas/share +/mnt/nas +not responding'
}

@test "a network mount that answers is sized" {
  FAKE_NAS=/mnt/nas run "$STORAGE" overview
  assert_output --regexp '//nas/share +1\.9T  /mnt/nas .* 70%  559G free'
}

@test "reclaim runs nothing unless the answer is y" {
  printf 'marker|~/stuff|touch %q\n' "$SANDBOX/ran" >>"$STORAGE_BUCKETS"
  "$STORAGE" scan 2>/dev/null
  run "$STORAGE" reclaim marker <<<$'n\nx'
  assert_success
  assert_output --partial 'Cancelled, nothing ran.'
  [ ! -e "$SANDBOX/ran" ] || fail "reclaim ran without a y"
  run "$STORAGE" reclaim marker <<<$'y\nx'
  assert_success
  [ -e "$SANDBOX/ran" ] || fail "reclaim did not run on y"
}

@test "buckets that add up to more than a compressed drive has used say so" {
  "$STORAGE" scan 2>/dev/null
  # Shrink the root drive's used space below what du counted for its buckets.
  sed -i 's/"fsused": 1800000000000/"fsused": 1000/' "$FAKE_LSBLK"
  run "$STORAGE" preview other:/
  assert_success
  run "$STORAGE" --list
  assert_regex "$(field other:/ 3 <<<"$output")" ' 0  .*none \(compressed fs\)'
}
