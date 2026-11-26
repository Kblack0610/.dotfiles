# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# fleet-worker-panel.sh - a checkout's git facts where the checkout is. fleet-sessions sources it for
# ahead_files and dirty_paths; fleet_host_panel (fleet-hosts.sh) sends this file's text plus `wp_main` to
# a fleet worker as `bash -c`, so the worker needs agent-panel, git and jq, never this file deployed: the
# script a pass runs there is always the workstation's.
#
# wp_main prints the worker's `agent-panel list --json` rows, each with `git`, its checkout's facts, in
# the same ssh call. fleet-sessions turns them into the row's git facts (worker_git_facts) and looks its
# PR up in this machine's PR store. Its exit is agent-panel's: 3 is a read with a gap, whose rows still
# print; any other failure prints nothing. A row jq cannot read goes through as it came.
#
# git is {in: "gone"} when the cwd is missing, {in: 0} outside git, else {in: 1, main, origin, branch,
# head, upstream, unpushed, ahead, based, head_at, ahead_paths, dirty}: main is the repo's main checkout (a worker clones each repo at
# the path the workstation has it, so it names the clone there), unpushed the commits on HEAD that no
# remote ref holds, ahead and dirty as ahead_files and dirty_paths count them against origin's default
# branch (unlanded_files: in a submodule, off both its default branch and the superproject's pin), and
# ahead_paths names ahead_files' files and head_at is HEAD's committer epoch (superseded_here in fleet-sessions
# reads both).
#
# wp_base needs merge_proof_ref (agent-merge-proof.sh) defined first: fleet-sessions sources both
# files, and fleet_host_panel sends both texts.

# wp_base <dir> -> origin's default branch as a ref name (merge_proof_ref); nothing when it has none.
# Thinner than fleet-sessions' default_base, which needs gh and this machine's cache: it reads origin
# only, so a repo whose canonical remote is not origin (a Forgejo mirror) can read more files ahead.
wp_base() {
  MERGE_PROOF_REMOTE=origin merge_proof_ref "$1" && echo
}

# ahead_files <dir> <base>: files the branch changed since the merge base whose content in
# HEAD still differs from the base tip. A squash-merged branch, or a local merge commit
# whose content is already on origin, changed files that origin now has, so it counts 0.
# A branch that merged main while main merged it has two merge bases (a criss-cross); a file
# the branch only took in from the base differs from one of them, so it must differ from all.
ahead_files() {
  ahead_paths "$@" | grep -c . || true
}

# ahead_paths <dir> <base>: the files ahead_files counts, one repo-relative path per line.
ahead_paths() {
  local d="$1" base="$2" mbs mb changed
  mbs="$(git -C "$d" merge-base --all "$base" HEAD 2>/dev/null)" && [ -n "$mbs" ] || return 0
  changed="$(git -C "$d" diff --name-only "$base" HEAD 2>/dev/null | sort)"
  while read -r mb; do
    [ -n "$changed" ] || break
    changed="$(comm -12 <(git -C "$d" diff --name-only "$mb" HEAD 2>/dev/null | sort) <(printf '%s\n' "$changed"))"
  done <<<"$mbs"
  [ -z "$changed" ] || printf '%s\n' "$changed"
}

# submodule_pin <dir> [<base reader>] -> the commit the superproject's default branch pins for <dir> (when
# <dir> is a submodule and this clone has that commit), else nothing. <base reader> names that branch for
# the superproject: wp_base by default, and fleet-sessions' pass_base in a pass. A submodule's own default
# branch says nothing about what landed: the pin may sit on a pin-merge commit another session owns, off
# master by design (2026-11-16 unity-core-playground-agent-20 read STALLED "3 file(s) not on the default
# branch" with a clean tree and HEAD the pin on origin/main).
submodule_pin() {
  local d="$1" read_base="${2:-wp_base}" sup top rel base pin
  sup="$(git -C "$d" rev-parse --show-superproject-working-tree 2>/dev/null)"
  [ -n "$sup" ] || return 0
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"
  rel="${top#"$sup"/}"
  base="$("$read_base" "$sup")"
  [ -n "$base" ] || return 0
  pin="$(git -C "$sup" ls-tree "$base" -- "$rel" 2>/dev/null | awk '$2 == "commit" { print $3; exit }')"
  [ -n "$pin" ] && git -C "$d" cat-file -e "$pin^{commit}" 2>/dev/null && echo "$pin"
  return 0
}

# unlanded_files <dir> <base> [<base reader>] -> ahead_files against <base>, except that in a submodule
# work is landed once it is on <base> or pinned by the superproject's default branch (submodule_pin, with
# <base reader>): the files off both. The one count every reader of "not on the default branch" takes.
unlanded_files() {
  local d="$1" base="$2" ahead pin pahead
  ahead="$(ahead_files "$d" "$base")"
  if [ "$ahead" -gt 0 ]; then
    pin="$(submodule_pin "$d" "${3:-wp_base}")"
    if [ -n "$pin" ]; then
      pahead="$(ahead_files "$d" "$pin")"
      [ "$pahead" -lt "$ahead" ] && ahead="$pahead"
    fi
  fi
  echo "$ahead"
}

# dirty_paths <dir> <edited files, one absolute path per line> [<foreign>]: the session's dirty files,
# one repo-relative path per line. In its own worktree (under ~/.worktrees/) every dirty file
# is its own. A repo's main checkout is shared with the human and other sessions, so there
# only the files this session edited count: the human's half-done config is not this
# session's to land. <foreign> (1) marks a worktree the session edited that is not its own
# cwd (edited_work_blockers): there a submodule pointer is another writer's (foreign_pin).
# -z: no quoting of odd names; --no-renames: one record per path.
dirty_paths() {
  local d="$1" edited="$2" foreign="${3:-}" top
  # Recursive status across many worktrees multiplies index reader and preload threads.
  # Keep these scans serial without changing the repo config or hiding submodule dirt. A read takes
  # no optional index.lock: a pass killed mid-scan would leave one and fail the repo's next commit.
  case "$d/" in
    "$HOME/.worktrees/"*)
      git --no-optional-locks -C "$d" -c index.threads=1 -c core.preloadIndex=false status --porcelain -z --no-renames 2>/dev/null \
        | while IFS= read -r -d '' e; do
            submodule_noise "$d" "$e" || { [ -n "$foreign" ] && foreign_pin "$d" "${e:3}" "$edited"; } || printf '%s\n' "${e:3}"
          done; return ;;
  esac
  [ -n "$edited" ] || return 0
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 0
  # -uall: an untracked file inside a new dir is listed by name, as edited_files names it.
  git --no-optional-locks -C "$d" -c index.threads=1 -c core.preloadIndex=false status --porcelain -z --no-renames -uall 2>/dev/null \
    | while IFS= read -r -d '' e; do submodule_noise "$top" "$e" || printf '%s/%s\n' "$top" "${e:3}"; done \
    | grep -xFf <(printf '%s\n' "$edited" | xargs -r -d '\n' realpath -m -- 2>/dev/null | grep .) \
    | cut -c"$(( ${#top} + 2 ))"-
}

# submodule_noise <dir> <status record>: a submodule entry that is not the session's work, by
# empty_submodule or moved_pin. Never a plain file.
submodule_noise() {
  local d="$1" e="$2"
  empty_submodule "$d" "${e:3}" || { [ "${e:0:2}" = " M" ] && moved_pin "$d" "${e:3}"; }
}

# foreign_pin <dir> <path> <edited files>: a submodule pointer in a worktree the session edited but
# does not sit in, with no edited path at or inside that submodule. The session that owns that tree,
# or a canary cut at an old commit, moved or staged the pin (a staged pin moved_pin keeps), so it is
# not this session's to land (ar-5937). Only a bare pointer: a working or untracked file inside the
# submodule, or a commit there no remote ref holds, is work a Bash edit (not in edited_files) may have
# made, so it stays dirt. -z and literal pathspecs: odd names match as status -z prints them.
foreign_pin() {
  local d="$1" path="$2" edited="$3" sub f
  [ -e "$d/$path/.git" ] || return 1
  [ "$(git --literal-pathspecs -C "$d" ls-files -s -z -- "$path" 2>/dev/null | head -c 7)" = "160000 " ] || return 1
  sub="$(realpath -m -- "$d/$path")"
  while IFS= read -r f; do
    [[ "$f" == "$sub" || "$f" == "$sub"/* ]] && return 1
  done < <(printf '%s\n' "$edited" | xargs -r -d '\n' realpath -m -- 2>/dev/null)
  [ -z "$(git -C "$d/$path" rev-list -1 HEAD --not --remotes 2>/dev/null)" ] || return 1
  [ -z "$(git --no-optional-locks -C "$d/$path" -c index.threads=1 -c core.preloadIndex=false status --porcelain --ignore-submodules=none 2>/dev/null)" ]
}

# moved_pin <dir> <path>: a submodule whose checkout sits at another commit than the index pin
# (` M`, nothing staged) with its own tree clean. A canary worktree cut at an old commit reads it
# for the pointers the stow and the shared clones moved on (.local/src/android-suite, gungan:
# ar-4016, razer dotfiles-agent-17 and -18 read STALLED). A staged pin, a commit no remote ref
# holds, or any working or untracked file inside the submodule is still the session's work.
moved_pin() {
  local d="$1" path="$2" mode
  mode="$(git -C "$d" ls-tree HEAD -- "$path" 2>/dev/null)" && [ "${mode%% *}" = 160000 ] || return 1
  [ -e "$d/$path/.git" ] || return 1
  # A commit no remote ref holds is the session's own unpushed work, however the pin reads.
  [ -z "$(git -C "$d/$path" rev-list -1 HEAD --not --remotes 2>/dev/null)" ] || return 1
  [ -z "$(git --no-optional-locks -C "$d/$path" -c index.threads=1 -c core.preloadIndex=false status --porcelain --ignore-submodules=none 2>/dev/null)" ]
}

# empty_submodule <dir> <path>: a submodule cloned with --no-checkout has HEAD but no index entries
# or working files, so status reports every file as a staged deletion though nothing was touched
# (ar-1057: finished sessions read STALLED). Only at the unchanged pin; a populated index, a working
# file or a staged or content-dirty moved pin is still dirt (an unstaged clean one is moved_pin's).
empty_submodule() {
  local d="$1" path="$2" pin staged head gitdir files
  [ -e "$d/$path/.git" ] || return 1
  pin="$(git -C "$d" rev-parse "HEAD:$path" 2>/dev/null)" || return 1
  staged="$(git -C "$d" rev-parse ":$path" 2>/dev/null)" || return 1
  head="$(git -C "$d/$path" rev-parse HEAD 2>/dev/null)" || return 1
  [ "$pin" = "$head" ] && [ "$staged" = "$head" ] || return 1
  # No index file at all: a `git rm -r .` leaves an empty one, and that deletion is real dirt.
  gitdir="$(git -C "$d/$path" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ ! -e "$gitdir/index" ] || return 1
  files="$(find "$d/$path" -mindepth 1 -name .git -prune -o ! -type d -print -quit 2>/dev/null)" || return 1
  [ -z "$files" ] || return 1
  files="$(git -C "$d/$path" ls-files 2>/dev/null)" || return 1
  [ -z "$files" ]
}

# wp_git <dir> <edited files> -> the row's `git` object. `based` says HEAD shares history with the base,
# so an `ahead` of 0 was measured, not a count ahead_files could not make (no merge base reads 0).
wp_git() {
  local d="$1" edited="$2" common main base up origin ahead apaths=""
  [ -n "$d" ] && [ -d "$d" ] || { echo '{"in":"gone"}'; return; }
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || { echo '{"in":0}'; return; }
  # A credential in an https remote stays on the worker: the rows are published (worker-panel.json).
  origin="$(git -C "$d" remote get-url origin 2>/dev/null)"
  [[ "$origin" =~ ^([a-z+]+://)[^/@]+@(.*)$ ]] && origin="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  common="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  case "$common" in */.git) main="${common%/.git}" ;; *) main="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" ;; esac
  base="$(wp_base "$d")"
  up="$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"
  ahead="$(unlanded_files "$d" "$base")"
  # The names only for a short list: superseded_here needs them for a draft branch, and a stale clone far
  # behind its base would ship thousands per row. Past the cap the list is empty, which holds the branch.
  [ "${ahead:-0}" = 0 ] || [ "$ahead" -gt "${WP_AHEAD_PATHS_MAX:-100}" ] || apaths="$(ahead_paths "$d" "$base")"
  dirty_paths "$d" "$edited" | jq -Rsc \
    --arg main "$main" \
    --arg origin "$origin" \
    --arg branch "$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    --arg head "$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null)" \
    --arg up "${up#*/}" \
    --arg unpushed "$(git -C "$d" rev-list --count HEAD --not --remotes 2>/dev/null)" \
    --arg ahead "$ahead" \
    --arg based "$(git -C "$d" merge-base HEAD "$base" >/dev/null 2>&1 && echo 1)" \
    --arg apaths "$apaths" \
    --arg hat "$(git -C "$d" log -1 --format=%ct HEAD 2>/dev/null)" \
    '{in: 1, $main, $origin, $branch, $head, upstream: $up, unpushed: ($unpushed | tonumber? // 0),
      ahead: ($ahead | tonumber? // 0), based: ($based == "1"), head_at: ($hat | tonumber? // null),
      ahead_paths: ($apaths | split("\n") | map(select(. != ""))), dirty: (split("\n") | map(select(. != "")))}'
}

# wp_main -> this machine's agent-panel rows, each with its `git` (wp_git); agent-panel's exit.
wp_main() {
  local out rc=0 row f g
  out="$(agent-panel list --json)" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || return "$rc"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # One jq: the cwd, then each edited file on its own line. A row it cannot read reads as gone, and
    # the merge below passes it through as it came.
    mapfile -t f < <(jq -r '.cwd // "", (.edited_files // [])[]' <<<"$row" 2>/dev/null)
    g="$(wp_git "${f[0]:-}" "$(printf '%s\n' "${f[@]:1}")")"
    jq -c --argjson g "$g" '. + {git: $g}' <<<"$row" 2>/dev/null || printf '%s\n' "$row"
  done <<<"$out"
  return "$rc"
}
