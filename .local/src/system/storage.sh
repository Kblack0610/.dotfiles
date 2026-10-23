#!/usr/bin/env bash
# storage - where the disk space went, on every drive in the machine.
#
#   storage                  the picker (enter browse, ctrl-x reclaim, ctrl-r rescan)
#   storage scan [label...]  size every bucket (or just these) into the cache; slow
#   storage waybar           the bar's JSON: root use% as text, the overview as tooltip
#   storage overview [mode]  the overview as text; mode is plain, ansi or pango
#   storage --list | preview <label> | reclaim <label> | browse <path> | drives
#
# Drives are read live on every call (cheap). Bucket sizes come only from the cache, since
# sizing ~2 TB takes minutes and waybar re-runs this every minute. Buckets, the cache layout
# and troubleshooting: README.md beside this file.

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/../tmux/panel-lib.sh" || exit 1

STORAGE_BUCKETS="${STORAGE_BUCKETS:-${XDG_CONFIG_HOME:-$HOME/.config}/storage/buckets}"
STORAGE_CACHE="${STORAGE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/storage}"
STORAGE_CRIT="${STORAGE_CRIT:-90}"               # use% at which a drive (and the bar) goes red
STORAGE_NET_TIMEOUT="${STORAGE_NET_TIMEOUT:-2}"  # seconds before a network mount counts as hung
STORAGE_TOP="${STORAGE_TOP:-8}"                  # rows in the tooltip's "Biggest" section
STORAGE_ICON="${STORAGE_ICON:-$''}"        # the glyph the built-in disk module used

SCAN="$STORAGE_CACHE/scan.tsv"     # bytes, label, path, device key, mount target, reclaim
KIDS="$STORAGE_CACHE/children"     # one <label>.tsv per bucket: bytes, child name
REAP="$STORAGE_CACHE/reapable.tsv" # count, bytes of the worktrees `wt gc` would reap

# Rows passed between functions are split on this, not on tab: tab is IFS whitespace, so
# `read` merges a run of tabs and an empty field (no reclaim command) shifts every one after it.
US=$'\037'

# --- Formatting ---------------------------------------------------------------

hsize() {
  if [ "${1:-0}" -gt 0 ] 2>/dev/null; then numfmt --to=iec -- "$1"; else printf '0'; fi
}

# df's Use%: used / (used + avail), rounded up, so the number matches what `df -h` prints.
pct_of() {
  local t=$(($1 + $2))
  if [ "$t" -gt 0 ]; then printf '%s' $(((($1 * 100) + t - 1) / t)); else printf '0'; fi
}

bar() {
  local n=$((($1 + 5) / 10)) i s=''
  for ((i = 0; i < 10; i++)); do
    if [ "$i" -lt "$n" ]; then s+='█'; else s+='░'; fi
  done
  printf '%s' "$s"
}

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# emph <mode> <crit|head|dim|none> <text> -- the one place markup is chosen, and for pango the
# one place text is escaped, so nothing reaches the tooltip unescaped.
emph() {
  local mode=$1 kind=$2 s=$3
  case "$mode" in
  pango)
    s=${s//&/&amp;} s=${s//</&lt;} s=${s//>/&gt;}
    case "$kind" in
    crit) s="<span color='#e06c75'><b>$s</b></span>" ;;
    head) s="<b>$s</b>" ;;
    dim) s="<span alpha='60%'>$s</span>" ;;
    esac
    ;;
  ansi)
    case "$kind" in
    crit) s="$C_ERR$s$C_OFF" ;;
    head) s="$C_HEAD$s$C_OFF" ;;
    dim) s="$C_DIM$s$C_OFF" ;;
    esac
    ;;
  esac
  printf '%s\n' "$s"
}

pause() {
  printf '\n%s[any key]%s' "$C_DIM" "$C_OFF"
  read -rsn1 _
}

# --- Sources ------------------------------------------------------------------

# label<TAB>path<TAB>reclaim, with ~ expanded and comments dropped.
bucket_rows() {
  [ -r "$STORAGE_BUCKETS" ] || return 0
  local label path reclaim
  while IFS='|' read -r label path reclaim || [ -n "$label" ]; do
    case "$label" in '' | '#'*) continue ;; esac
    [ "${path:0:1}" = '~' ] && path="$HOME${path:1}"
    printf '%s%s%s%s%s\n' "$label" "$US" "$path" "$US" "$reclaim"
  done <"$STORAGE_BUCKETS"
}

# One row per filesystem worth showing, mounted or not:
#   disk  model  key  fstype  mountpoint  size  used  avail      (bytes)
# key is the device that holds the filesystem (a partition, or its LUKS/LVM child), the same
# name findmnt reports as SOURCE, which is how a bucket is matched to its drive. EFI-sized
# vfat partitions are dropped: they are boot plumbing, not storage. A btrfs root mounted at
# several subvolumes reports "/" as its mountpoint.
drive_rows() {
  lsblk -J -b -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS,FSSIZE,FSUSED,FSAVAIL 2>/dev/null | jq -r '
    def mp: [(.mountpoints // [])[] | select(. != null and . != "[SWAP]")] | unique
            | if any(.[]; . == "/") then "/" else (.[0] // "") end;
    def leaf: if ((.children // []) | length) > 0 then (.children[0] | leaf) else . end;
    .blockdevices[]
    | select(.type == "disk" and ((.name | test("^(zram|loop|ram|sr)")) | not))
    | . as $d
    | (if (($d.children // []) | length) == 0 then [$d] else $d.children end)[]
    | . as $p
    | ($p | leaf) as $l
    | select((($l.fstype // "") != "vfat") or (($p.size // 0) > 2147483648))
    | [$d.name, (($d.model // "") | sub("\\s+$"; "")), $l.name, ($l.fstype // ""), ($l | mp),
       (($l.fssize // $p.size // 0) | tostring), (($l.fsused // "") | tostring),
       (($l.fsavail // "") | tostring)]
    | join("\u001f")'
}

drives() {
  [ -n "${DRIVES+set}" ] || DRIVES=$(drive_rows)
  printf '%s\n' "$DRIVES"
}

# Every row the picker and the tooltip show, biggest first:
#   bytes  label  path  mount  reclaim  kind(bucket|other)  name
# A bucket's mount comes from its drive's key, so every subvolume of the root btrfs files
# under "/" rather than under /home, /var/cache and the rest.
all_rows() {
  local scan=$SCAN
  [ -s "$scan" ] || scan=/dev/null
  awk -v OFS="$US" '
    FILENAME == ARGV[2] { if ($5 != "") { mp[$3] = $5; used[$3] = $7 }; next }
    {
      m = ($4 in mp) ? mp[$4] : $5
      print $1, $2, $3, m, $6, "bucket", $2
      sum[$4] += $1
    }
    END {
      for (k in mp) {
        # du counts what a file would take uncompressed, so on a compressed btrfs the
        # buckets can add up to more than the drive has used. Say so instead of a bare 0.
        o = used[k] - sum[k]; n = "everything else"
        if (o < 0) { o = 0; n = "none (compressed fs)" }
        print sprintf("%.0f", o), "other:" mp[k], mp[k], mp[k], "", "other", n
      }
    }
  ' FS="$US" <(drives) FS='\t' "$scan" | sort -t "$US" -k1,1nr
}

row_of() { all_rows | awk -F "$US" -v l="$1" '$2 == l { print; exit }'; }

# --- Scan ---------------------------------------------------------------------

# size_into <dir> <out> -- print dir's total bytes and write ALL its children to out
# (bytes<TAB>name, biggest first). All of them, not a top N: the worktree estimate below
# looks children up by name.
size_into() {
  local dir=$1 out=$2 raw="$2.raw.$$"
  nice -n 19 ionice -c 3 du -x -B1 -d 1 -- "$dir" 2>/dev/null >"$raw"
  awk -F'\t' -v d="$dir" '$2 == d { t = $1 } END { print t + 0 }' "$raw"
  awk -F'\t' -v d="$dir" -v OFS='\t' '$2 != d { n = $2; sub(".*/", "", n); print $1, n }' "$raw" |
    sort -t "$PANEL_TAB" -k1,1nr >"$out"
  rm -f "$raw"
}

# wt is the one reclaim that frees only PART of its bucket, and it can say which part: its own
# dry run names the worktrees it would reap, and the bucket's children are their sizes.
reap_estimate() {
  local wtlabel kids
  wtlabel=$(awk -F'\t' '$6 ~ /^wt gc/ { print $2; exit }' "$SCAN")
  if [ -z "$wtlabel" ] || ! panel_have wt; then
    rm -f "$REAP"
    return 0
  fi
  kids="$KIDS/$(slug "$wtlabel").tsv"
  PANEL_NO_COLOR=1 wt gc --dry-run 2>/dev/null |
    awk '$1 == "would" && $2 == "reap" { print $3 }' |
    awk -F'\t' 'FILENAME == "-" { want[$0] = 1; next }
                ($2 in want) { n++; b += $1 }
                END { printf "%d\t%.0f\n", n, b }' - "$kids" >"$REAP.tmp.$$" &&
    mv -f "$REAP.tmp.$$" "$REAP"
}

cmd_scan() {
  mkdir -p "$KIDS" || panel_die "cannot create $KIDS"
  exec 9>"$STORAGE_CACHE/scan.lock"
  if ! flock -n 9; then
    panel_hint "another scan is running; waiting for it to finish"
    flock 9
    return 0
  fi

  local tmp="$SCAN.tmp.$$" label path reclaim real src key target total want
  : >"$tmp"
  while IFS="$US" read -r label path reclaim; do
    if [ "$#" -gt 0 ]; then
      want=0
      for l in "$@"; do [ "$l" = "$label" ] && want=1; done
      if [ "$want" -eq 0 ]; then
        [ -s "$SCAN" ] && awk -F'\t' -v l="$label" '$2 == l' "$SCAN" >>"$tmp"
        continue
      fi
    fi
    [ -e "$path" ] || continue # not on this machine
    real=$(realpath -- "$path") || continue
    src=$(findmnt -n -o SOURCE -T "$real" 2>/dev/null | head -n 1)
    src=${src%%\[*} # btrfs appends the subvolume: /dev/nvme2n1p2[/@home]
    key=${src##*/}
    target=$(findmnt -n -o TARGET -T "$real" 2>/dev/null | head -n 1)
    printf '  sizing %-20s %s\n' "$label" "$real" >&2
    total=$(size_into "$real" "$KIDS/$(slug "$label").tsv")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$total" "$label" "$real" "$key" "$target" "$reclaim" >>"$tmp"
  done < <(bucket_rows)

  sort -t "$PANEL_TAB" -k1,1nr "$tmp" -o "$tmp" && mv -f "$tmp" "$SCAN"
  reap_estimate
}

# --- Overview -----------------------------------------------------------------

render_drives() {
  local mode=$1 disk model key fs mp size used avail pct state line
  while IFS="$US" read -r disk model key fs mp size used avail; do
    [ -n "$disk" ] || continue
    if [ -n "$mp" ] && [ -n "$used" ]; then
      pct=$(pct_of "$used" "$avail")
      state="$(hsize "$avail") free"
      findmnt -rn -o OPTIONS --mountpoint "$mp" 2>/dev/null | head -n 1 | grep -qE '^ro(,|$)' &&
        state+=", read-only"
      line=$(printf '%-8s %-28.28s %5s  %-14s %s %3s%%  %s' \
        "$disk" "$model" "$(hsize "$size")" "$mp" "$(bar "$pct")" "$pct" "$state")
      if [ "$pct" -ge "$STORAGE_CRIT" ]; then emph "$mode" crit "$line"; else emph "$mode" none "$line"; fi
    else
      case "$fs" in
      '') state='no filesystem' ;;
      swap) state='swap' ;;
      *) state="not mounted ($fs)" ;;
      esac
      emph "$mode" dim "$(printf '%-8s %-28.28s %5s  %s' "$disk" "$model" "$(hsize "$size")" "$state")"
    fi
  done < <(drives)
}

# Network mounts, each sized under a timeout so a hung NAS cannot freeze the bar.
render_net() {
  local mode=$1 tgt src out size used avail pct line
  while read -r tgt src; do
    if out=$(timeout "$STORAGE_NET_TIMEOUT" df -B1 --output=size,used,avail -- "$tgt" 2>/dev/null | tail -n 1) &&
      [ -n "$out" ]; then
      read -r size used avail <<<"$out"
      pct=$(pct_of "$used" "$avail")
      line=$(printf '%-35.35s %5s  %-14s %s %3s%%  %s free' \
        "$src" "$(hsize "$size")" "$tgt" "$(bar "$pct")" "$pct" "$(hsize "$avail")")
      if [ "$pct" -ge "$STORAGE_CRIT" ]; then emph "$mode" crit "$line"; else emph "$mode" none "$line"; fi
    else
      emph "$mode" crit "$(printf '%-35.35s        %-14s not responding' "$src" "$tgt")"
    fi
  done < <(findmnt -rn -t cifs,smb3,nfs,nfs4,fuse.sshfs,fuse.rclone -o TARGET,SOURCE 2>/dev/null)
}

render_biggest() {
  local mode=$1 bytes label path mount reclaim kind name
  while IFS="$US" read -r bytes label path mount reclaim kind name; do
    emph "$mode" none "$(printf '%7s  %-22.22s  %s' "$(hsize "$bytes")" "$name" "$mount")"
  done < <(all_rows | head -n "$STORAGE_TOP")
}

render_reclaim() {
  local mode=$1 bytes label path mount reclaim kind name n b total=0 any=0
  while IFS="$US" read -r bytes label path mount reclaim kind name; do
    [ -n "$reclaim" ] || continue
    if [ "${reclaim%% *}" = wt ] && [ -s "$REAP" ]; then
      IFS="$PANEL_TAB" read -r n b <"$REAP"
      bytes=${b:-0} name="$name ($n reapable)"
    fi
    any=1 total=$((total + bytes))
    emph "$mode" none "$(printf '%7s  %-30.30s  %s' "$(hsize "$bytes")" "$name" "$reclaim")"
  done < <(all_rows)
  if [ "$any" -eq 0 ]; then
    emph "$mode" dim "  nothing has a reclaim command (see $STORAGE_BUCKETS)"
  else
    emph "$mode" dim "$(printf '%7s  up to this much if you run all of them' "$(hsize "$total")")"
  fi
}

scan_age() {
  local s=$(($(date +%s) - $(stat -c %Y "$SCAN")))
  if [ "$s" -lt 3600 ]; then
    printf '%sm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then
    printf '%sh' $((s / 3600))
  else
    printf '%sd' $((s / 86400))
  fi
}

# cmd_overview [plain|ansi|pango] [full|header] -- header drops "Biggest", because in the
# picker the list below IS the biggest-first list.
cmd_overview() {
  local mode=${1:-plain} part=${2:-full} net
  emph "$mode" head "Drives"
  render_drives "$mode"
  net=$(render_net "$mode")
  if [ -n "$net" ]; then
    printf '\n'
    emph "$mode" head "Network"
    printf '%s\n' "$net"
  fi
  printf '\n'
  if [ ! -s "$SCAN" ]; then
    emph "$mode" crit "No scan yet - run: storage scan"
    return 0
  fi
  if [ "$part" = full ]; then
    emph "$mode" head "Biggest"
    render_biggest "$mode"
    printf '\n'
  fi
  emph "$mode" head "Reclaimable"
  render_reclaim "$mode"
  printf '\n'
  emph "$mode" dim "sizes scanned $(scan_age) ago (storage scan to refresh)"
}

cmd_waybar() {
  local used='' avail='' pct=0 cls='' text tip
  read -r used avail < <(df -B1 --output=used,avail / 2>/dev/null | tail -n 1)
  if [ -n "$used" ] && [ -n "$avail" ]; then
    pct=$(pct_of "$used" "$avail")
    text="$pct% $STORAGE_ICON"
    [ "$pct" -ge "$STORAGE_CRIT" ] && cls=critical
  else
    text="? $STORAGE_ICON" cls=warning
  fi
  tip="<tt>$(cmd_overview pango full)</tt>"
  jq -cn --arg text "$text" --arg tooltip "$tip" --arg class "$cls" --argjson percentage "$pct" \
    '{text: $text, tooltip: $tooltip, class: $class, percentage: $percentage}'
}

# --- Picker -------------------------------------------------------------------

cmd_list() {
  local bytes label path mount reclaim kind name mark
  while IFS="$US" read -r bytes label path mount reclaim kind name; do
    mark=''
    [ -n "$reclaim" ] && mark="${C_BOX}ctrl-x: $reclaim${C_OFF}"
    # Pad BEFORE colouring: printf counts escape bytes as width and truncates through them.
    name=$(printf '%-22.22s' "$name")
    [ "$kind" = other ] && name="${C_DIM}$name${C_OFF}"
    printf '%s\t%s\t%7s  %s  %-16.16s  %s\n' \
      "$path" "$label" "$(hsize "$bytes")" "$name" "$mount" "$mark"
  done < <(all_rows)
}

cmd_preview() {
  local bytes label path mount reclaim kind name
  IFS="$US" read -r bytes label path mount reclaim kind name < <(row_of "$1")
  [ -n "${label:-}" ] || panel_die "no such bucket: $1"
  [ "$kind" = other ] && name="everything else on $mount"
  panel_head "$name"
  printf '%s\n%s on %s\n' "$path" "$(hsize "$bytes")" "$mount"
  [ -n "$reclaim" ] && printf 'ctrl-x runs: %s\n' "$reclaim"
  printf '\n'
  if [ "$kind" = other ]; then
    panel_hint "Used space on this drive that is in no bucket."
    panel_hint "enter browses the whole drive; add a bucket to track a folder."
    return 0
  fi
  local kids b n
  kids="$KIDS/$(slug "$label").tsv"
  [ -s "$kids" ] || {
    panel_hint "no children recorded (ctrl-r to rescan)"
    return 0
  }
  while IFS="$PANEL_TAB" read -r b n; do
    printf '%7s  %s\n' "$(hsize "$b")" "$n"
  done < <(head -n 30 "$kids")
}

cmd_browse() {
  if ! panel_have dua; then
    printf 'dua is not installed. Install it with:\n\n  sudo pacman -S dua-cli\n'
    pause
    return 0
  fi
  dua --stay-on-filesystem interactive -- "$1"
}

cmd_reclaim() {
  local bytes label path mount reclaim kind name ans rc
  IFS="$US" read -r bytes label path mount reclaim kind name < <(row_of "$1")
  [ -n "${label:-}" ] || panel_die "no such bucket: $1"
  if [ -z "$reclaim" ]; then
    printf '%s has no reclaim command. Add one in %s.\n' "$name" "$STORAGE_BUCKETS"
    pause
    return 0
  fi
  printf 'Reclaim %s (%s at the last scan) by running:\n\n  %s\n\n' "$name" "$(hsize "$bytes")" "$reclaim"
  printf 'Type y to run it: '
  read -r ans
  if [ "$ans" != y ]; then
    printf 'Cancelled, nothing ran.\n'
    pause
    return 0
  fi
  bash -c "$reclaim"
  rc=$?
  printf '\n%s exited %s. Rescanning %s...\n' "$reclaim" "$rc" "$name"
  cmd_scan "$label"
  pause
}

cmd_drives() {
  lsblk -e 7 -o NAME,MODEL,SIZE,FSTYPE,LABEL,MOUNTPOINTS,FSUSE%,FSAVAIL
  if panel_have duf; then
    printf '\n'
    duf --only local,network
  fi
  pause
}

cmd_pick() {
  panel_need fzf jq
  if [ ! -s "$SCAN" ]; then
    panel_hint "No scan yet. Sizing every bucket now, which takes a few minutes on a full disk."
    cmd_scan
  fi
  panel_fzf_opts
  panel_fzf_table
  local me
  me=$(printf '%q' "$SELF")
  cmd_list | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" --with-nth=3 \
    --header="$(cmd_overview ansi header)" --header-first \
    --footer="enter browse | ctrl-x reclaim | ctrl-r rescan | ctrl-d drives | esc quit" \
    --preview="$me preview {2}" "$(panel_fzf_preview down 35)" \
    --bind="enter:execute($me browse {1})" \
    --bind="ctrl-x:execute($me reclaim {2})+reload($me --list)+transform-header($me overview ansi header)" \
    --bind="ctrl-r:execute($me scan)+reload($me --list)+transform-header($me overview ansi header)" \
    --bind="ctrl-d:execute($me drives)"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
'') cmd_pick ;;
scan)
  shift
  cmd_scan "$@"
  ;;
waybar) cmd_waybar ;;
overview) cmd_overview "${2:-plain}" "${3:-full}" ;;
--list) cmd_list ;;
preview) cmd_preview "${2:?usage: storage preview <label>}" ;;
browse) cmd_browse "${2:?usage: storage browse <path>}" ;;
reclaim) cmd_reclaim "${2:?usage: storage reclaim <label>}" ;;
drives) cmd_drives ;;
-h | --help | help) panel_usage ;;
*) panel_die "unknown verb: $1 (see storage --help)" ;;
esac
