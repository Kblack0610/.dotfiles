# shellcheck shell=bash
# test-pick.sh - which fast-tier test files a change can affect: tests/pick.sh (the PR gate)
# picks by it, and fleet-bench's hold check reads a merge's "area tests" by it.

# _test_pick_names <changed paths>: the words and parent/name paths test_picked matches, built
# once per change list. A shared basename has an extension and names two or more files outside
# tests/ in the repo this file sits in (README.md, lib.rs); an extensionless one is a command a
# test runs by bare name, so it stays a word even when .local/bin links it from .local/src or a
# stub in tests/helpers shadows it.
_TEST_PICK_REPO="$(git -C "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" rev-parse --show-toplevel 2>/dev/null || echo .)"
_test_pick_names() {
  [ "${_TEST_PICK_NAMES_FOR-}" = "$1" ] && return 0
  _TEST_PICK_NAMES_FOR="$1"
  local shared
  shared="$(git -C "$_TEST_PICK_REPO" ls-files 2>/dev/null | grep -v '^tests/' | sed 's#.*/##' | grep -E '.\.' | sort | uniq -d)"
  # The words as one ERE alternation, bounded by anything but a name character: `-` counts as
  # part of the name, so agentctl is not a word of agentctl-run.
  _TEST_PICK_WORDS="$(grep -v '^$' <<<"$1" | sed 's#.*/##' | sort -u | { grep -vxFf <(printf '%s\n' "$shared") || true; } |
    awk '{gsub(/[][\\.*^$+?(){}|]/, "\\\\&"); o=o (o==""?"":"|") $0} END {if (o!="") printf "(^|[^A-Za-z0-9_-])(%s)($|[^A-Za-z0-9_-])", o}')"
  # Each of those words with the directory its changed file sits in, `<word><TAB><dir>` (an empty
  # dir at the root), for _test_pick_otherdir.
  _TEST_PICK_PARENTS="$(grep -v '^$' <<<"$1" | awk -F/ 'NR==FNR {s[$0]; next} !($NF in s) {print $NF "\t" (NF > 1 ? $(NF-1) : "")}' \
    <(printf '%s\n' "$shared") - | sort -u)" || true
  _TEST_PICK_PATHS="$(grep -v '^$' <<<"$1" | grep '/' | awk -F/ 'NR==FNR {d[$0]; next} ($NF in d) {print $(NF-1) "/" $NF}' \
    <(printf '%s\n' "$shared") - | sort -u)" || true
  _TEST_PICK_PATHS_RE="$(awk '{gsub(/[][\\.*^$+?(){}|]/, "\\\\&"); o=o (o==""?"":"|") $0} END {printf "%s", o}' <<<"$_TEST_PICK_PATHS")"
  # Every tracked file with one of those basenames: a longer path that names one which did not
  # change is not a use of the one that did (_test_pick_path_named).
  _TEST_PICK_SHARED_FILES="$(git -C "$_TEST_PICK_REPO" ls-files 2>/dev/null |
    awk -F/ 'NR==FNR {sub(/.*\//, ""); b[$0]; next} ($NF in b)' <(printf '%s\n' "$_TEST_PICK_PATHS") -)" || true
  # The fixture entries the change touches (tests/fixtures/<top>/...), as one ERE for a test that
  # names one (`fixtures/<top>`) or seeds its sandbox from one (`sandbox_init <top>`).
  _TEST_PICK_FIXTURES="$(sed -n 's#^tests/fixtures/\([^/]*\).*#\1#p' <<<"$1" | sort -u |
    awk '{gsub(/[][\\.*^$+?(){}|]/, "\\\\&"); o=o (o==""?"":"|") $0}
    END {if (o!="") printf "(fixtures/|sandbox_init[[:space:]]+)(%s)($|[^A-Za-z0-9._-])", o}')" || true
  # The changed paths with a directory in them, as one ERE bounded like a path: the one-level read
  # of a script a test runs (test_picked) matches only these.
  _TEST_PICK_HOP="$(grep '/' <<<"$1" | awk '{gsub(/[][\\.*^$+?(){}|]/, "\\\\&"); o=o (o==""?"":"|") $0}
    END {if (o!="") printf "(^|[^A-Za-z0-9._-])(%s)($|[^A-Za-z0-9._-])", o}')" || true
}
# _test_pick_aliases: `VAR repo-path` for each `VAR="$REPO_ROOT/<path>"` the shared helpers
# (tests/helpers/*.bash) define, and one ERE for a use of any of those variables, built once.
_test_pick_aliases() {
  [ -n "${_TEST_PICK_ALIASES+x}" ] && return 0
  _TEST_PICK_ALIASES="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)="\$\{?REPO_ROOT\}?\/([^" ]+)".*/\2 \3/p' \
    "$_TEST_PICK_REPO"/tests/helpers/*.bash 2>/dev/null)" || true
  _TEST_PICK_ALIAS_RE="$(awk 'NF {o=o (o==""?"":"|") $1} END {if (o!="") printf "\\$\\{?(%s)([^A-Za-z0-9_]|$)", o}' <<<"$_TEST_PICK_ALIASES")"
}

# _test_pick_expand <changed paths>: the list with the scripts that source a changed
# .local/lib/*.sh added, to any depth (a lib that sources a lib): a test names release-state, not
# store-auth.sh, so a change to .local/lib/store-auth.sh picked none of store_sales, release_state
# or store_reviews (ar-2508). A source line is an uncommented `. <path>` or `source <path>` that
# names the lib's basename; the result is _TEST_PICK_EXT, built once per change list.
_test_pick_expand() {
  [ "${_TEST_PICK_EXT_FOR-}" = "$1" ] && return 0
  _TEST_PICK_EXT_FOR="$1" _TEST_PICK_EXT="$1"
  local libs seen="" new f
  new="$(grep -E '^\.local/lib/[^/]+\.sh$' <<<"$1" | sed 's#.*/##')" || true
  while [ -n "$new" ]; do
    seen+="$new"$'\n'
    local -a args=()
    while read -r f; do args+=(-e "$f"); done <<<"$new"
    libs="$(git -C "$_TEST_PICK_REPO" grep -nIF "${args[@]}" 2>/dev/null |
      awk -F: -v names="$(tr '\n' '|' <<<"$new")" '
        BEGIN { n = split(names, nm, "|") }
        { f = $1; t = substr($0, length($1 ) + length($2) + 3)
          if (t ~ /^[[:space:]]*#/ || t !~ /(^|[[:space:];&|({])(\.|source)[[:space:]]/) next
          for (i = 1; i <= n; i++) {
            if (nm[i] == "") continue
            j = index(t, nm[i]); post = substr(t, j + length(nm[i]), 1)
            if (j > 0 && post !~ /[A-Za-z0-9_.-]/) { print f; break }
          } }' | sort -u)" || true
    _TEST_PICK_EXT="$(printf '%s\n%s\n' "$_TEST_PICK_EXT" "$libs" | grep -v '^$' | sort -u)"
    # The next round: dependents that are libs themselves and were not looked up yet.
    new="$(grep -E '^\.local/lib/[^/]+\.sh$' <<<"$libs" | sed 's#.*/##' | { grep -vxFf <(printf '%s' "$seen") || true; })" || true
  done
}

# test_picked <changed paths, one a line> <test path, repo-relative>, the test's text on stdin:
# status 0 when that test is picked. A test is picked when it or a file it loads from beside it
# changed, (a script that sources a changed
# .local/lib/*.sh counts as changed: _test_pick_expand), or its text with what it loads names a changed file's basename (not as a stub or a
# directory) or a directory a changed file sits under as `<dir>/` or `<dir>/*...` (a glob such as
# `.claude/hooks/stop-post.d/*.sh`), or a script it runs as `$REPO_ROOT/<path>` (or through a
# helper's variable for one) names a changed path in its code, or a test-side file it runs as
# `$BATS_TEST_DIRNAME/../<dir>/<file>` changed or names that directory, or it names a changed fixture
# entry; a change to the shared harness (helpers, vendor, fixtures/basic, Makefile, run-bats.sh)
# picks every file.

# _test_pick_unstub: stdin to stdout, each `stub <name> '<body>'` line without the uses of <name>
# inside its quoted body, which are the fake naming itself. A use that is part of a path (a
# passthrough's `exec "$REPO_ROOT/.local/bin/<name>"`) or anything after the body stays.
_test_pick_unstub() {
  awk '{
    if (!match($0, /(^|[[:space:];&|(])stub[[:space:]]+[^[:space:]]+[[:space:]]+["'"'"']/)) { print; next }
    head = substr($0, 1, RSTART + RLENGTH - 1); rest = substr($0, RSTART + RLENGTH)
    q = substr(head, length(head), 1); name = head
    sub(/[[:space:]]+.$/, "", name); sub(/.*stub[[:space:]]+/, "", name)
    for (i = 1; i <= length(rest); i++) {
      c = substr(rest, i, 1)
      if (q == "\"" && c == "\\") i++
      else if (c == q) break
    }
    body = substr(rest, 1, i - 1); tail = substr(rest, i); out = ""
    while ((n = index(body, name)) > 0) {
      pre = substr(body, n - 1, 1); post = substr(body, n + length(name), 1)
      if (n > 1 && pre ~ /[A-Za-z0-9_.\/-]/ || post ~ /[A-Za-z0-9_.\/-]/) out = out substr(body, 1, n + length(name) - 1)
      else out = out substr(body, 1, n - 1)
      body = substr(body, n + length(name))
    }
    print head out body tail
  }'
}

# _test_pick_uncomment: stdin to stdout without comments: whole comment lines, and the tail of a
# line from a `#` that starts a word outside quotes (`"issue #12" | agentctl add` keeps its name).
# A line whose quotes do not close keeps its tail. fleet_dispatch/common.bash ends a code line with
# "so no pass asks fleet-bench for canaries", which picked all ten fleet_dispatch*.bats files
# (~3,500 s of the unit tier) for a fleet-bench change although it stubs fleet-bench (#3104, ar-3036).
_test_pick_uncomment() {
  awk '/^[[:space:]]*#/ { next }
    {
      q = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q == "'"'"'") { if (c == q) q = ""; continue }
        if (c == "\\") { i++; continue }
        if (q == "\"") { if (c == q) q = ""; continue }
        if (c == "\"" || c == "'"'"'") q = c
        else if (c == "#" && substr($0, i - 1, 1) ~ /[[:space:]]/) { $0 = substr($0, 1, i - 1); break }
      }
      print
    }'
}

# _test_pick_otherdir: stdin to stdout without each changed word that ends a path in another
# directory: `<dir>/<word>` where <dir> is a literal name (not a variable, `.` or `..`) other than
# the one its changed file sits in. `mkdir -p "$HOME/.config/fleet-bench"` names a config
# directory, not .local/bin/fleet-bench (ar-3036); `$REPO_ROOT/.local/bin/fleet-bench` and
# `"$BIN/fleet-bench"` stay.
_test_pick_otherdir() {
  [ -n "$_TEST_PICK_PARENTS" ] || { cat; return 0; }
  # The pairs go through the environment: a -v value with a newline in it fails in BSD awk.
  PICK_PARENTS=$_TEST_PICK_PARENTS awk 'BEGIN {
      n = split(ENVIRON["PICK_PARENTS"], l, "\n")
      for (i = 1; i <= n; i++) { split(l[i], f, "\t"); if (!(f[1] in dirs)) names[++k] = f[1]; dirs[f[1]] = dirs[f[1]] " " f[2] " " }
    }
    {
      for (i = 1; i <= k; i++) {
        name = names[i]; s = $0; out = ""
        while ((j = index(s, "/" name)) > 0) {
          pre = substr(s, 1, j - 1); post = substr(s, j + 1 + length(name), 1); keep = 1
          if (post !~ /[A-Za-z0-9_-]/ && match(pre, /[A-Za-z0-9._-]+$/)) {
            dir = substr(pre, RSTART); before = substr(pre, RSTART - 1, 1)
            if (dir != "." && dir != ".." && before != "$" && before != "{" && index(dirs[name], " " dir " ") == 0) keep = 0
          }
          out = out substr(s, 1, j) (keep ? name : ""); s = substr(s, j + 1 + length(name))
        }
        $0 = out s
      }
      print
    }'
}

# _test_pick_path_named <changed> <text>: status 0 when the text names a changed shared basename as
# `<parent>/<name>`, other than as the tail of a longer path that is a tracked file which did not
# change. fleet_dispatch/common.bash reads .local/src/notes-cli/src/projects.rs, so a change to
# hub-core's or agent-web's src/projects.rs picked every fleet_dispatch*.bats file (ar-3036).
_test_pick_path_named() {
  local tok c f other
  while read -r tok; do
    [ -n "$tok" ] || continue
    while read -r c; do
      case "$tok" in "$c" | */"$c") return 0 ;; esac
      case "$c" in "$tok" | */"$tok") return 0 ;; esac
    done <<<"$1"
    other=
    while read -r f; do
      case "$tok" in "$f" | */"$f") other=1 && break ;; esac
    done <<<"$_TEST_PICK_SHARED_FILES"
    [ -n "$other" ] || return 0
  done < <(grep -oE "[A-Za-z0-9._/-]*($_TEST_PICK_PATHS_RE)" <<<"$2")
  return 1
}

test_picked() {
  grep -qE '^tests/(helpers|vendor|fixtures/basic)/|^tests/(Makefile|run-bats\.sh)$' <<<"$1" && return 0
  _test_pick_expand "$1"
  set -- "$_TEST_PICK_EXT" "$2"
  grep -qxF "$2" <<<"$1" && return 0
  local text rel inc new more seen=$'\n'
  text="$(cat)" new=$text
  # A file the test loads from beside it (`load 'fleet_dispatch/common'`) is part of its text, and
  # a change to it picks the test; so is a file that one loads, to any depth. bats resolves `load
  # x` against the test's own directory, as x.bash and then x. The shared harness (../helpers,
  # ../vendor) is matched above.
  while [ -n "$new" ]; do
    more=
    while read -r rel; do
      case $rel in ../* | /*) continue ;; esac
      grep -qxF -e "${2%/*}/$rel.bash" -e "${2%/*}/$rel" <<<"$1" && return 0
      inc="${2%/*}/$rel.bash"
      [ -f "$_TEST_PICK_REPO/$inc" ] || inc="${2%/*}/$rel"
      [ -f "$_TEST_PICK_REPO/$inc" ] || continue
      [[ $seen == *$'\n'"$inc"$'\n'* ]] && continue
      seen+=$inc$'\n'
      more+=$'\n'"$(cat "$_TEST_PICK_REPO/$inc")"
    done < <(sed -nE "s/^[[:space:]]*load[[:space:]]+['\"]?([^'\" ]+).*/\1/p" <<<"$new")
    text+=$more new=$more
  done
  # A test-side file the test runs from a sibling directory of tests/ (`node --test
  # "$BATS_TEST_DIRNAME/../agent-web/readers.test.mjs"`) picks the test when it changes, and the
  # directories it names count as the test's (the last check below): readers.test.mjs reads
  # .local/src/agent-web/src/, so #3200's change there was not picked and went red on main
  # (ar-4674). Its words do not count: the node tests quote `agent-ask` as text a card shows. helpers
  # and vendor are the harness above; a fixture is data, matched below. A file directly in tests/
  # (pick.sh, shard.sh) is one the test names by basename already; read for its directories, it
  # would pick pick.bats and shard.bats on almost every change.
  local up=${2%/*} side=
  case $up in */*) up=${up%/*} ;; *) up=. ;; esac
  while read -r rel; do
    case $rel in helpers/* | vendor/* | fixtures/* | */) continue ;; */*) ;; *) continue ;; esac
    inc="$up/$rel"
    grep -qxF "$inc" <<<"$1" && return 0
    [ -f "$_TEST_PICK_REPO/$inc" ] || continue
    [[ $seen == *$'\n'"$inc"$'\n'* ]] && continue
    seen+=$inc$'\n'
    side+=$'\n'"$(cat "$_TEST_PICK_REPO/$inc")"
  done < <(grep -oE '\$\{?BATS_TEST_DIRNAME\}?/\.\./[A-Za-z0-9_-][A-Za-z0-9._/-]*' <<<"$text" | sed -E 's#^[^/]*/\.\./##' | sort -u)
  # A script the shared helpers name for every test (sandbox.bash: AGENT_ASK="$REPO_ROOT/.local/bin/
  # agent-ask") is named where the test's code uses its variable: questions_panel.bats runs agent-ask
  # only as "$AGENT_ASK", so #2385's agent-ask change was not picked and went red on main (ar-4309).
  local var ref code
  _test_pick_aliases
  code="$(_test_pick_uncomment <<<"$text")"
  if [ -n "$_TEST_PICK_ALIAS_RE" ]; then
    while read -r var ref; do
      code+=$'\n'"\$REPO_ROOT/$ref" text+=$'\n'"\$REPO_ROOT/$ref"
    done < <(grep -oE "$_TEST_PICK_ALIAS_RE" <<<"$code" | sed -E 's/^\$\{?([A-Za-z0-9_]+).*/\1/' | sort -u |
      awk 'NR==FNR {u[$1]; next} ($1 in u)' - <(printf '%s\n' "$_TEST_PICK_ALIASES"))
  fi
  # A repo script the test runs by path is read one level down, for the whole repo paths its code
  # names: worktree_create_hook.bats runs worktree-remove.sh, which runs .local/src/tmux/worktree.sh
  # by path, so #2127's worktree.sh change was not picked and went red on main (ar-4309). Only a
  # changed path with a directory in it counts there, never a bare name, so a script that runs
  # fifty commands by name picks no more tests than before.
  _test_pick_names "$1"
  if [ -n "$_TEST_PICK_HOP" ]; then
    while read -r ref; do
      case $ref in tests/* | '') continue ;; esac
      [ -f "$_TEST_PICK_REPO/$ref" ] || continue
      # Not a pipe: grep -q stops at the first match, and under the callers' pipefail sed's SIGPIPE
      # on a large script would turn that match into a failure.
      grep -qE "$_TEST_PICK_HOP" <(_test_pick_uncomment <"$_TEST_PICK_REPO/$ref") && return 0
    done < <(grep -oE '\$\{?REPO_ROOT\}?/[A-Za-z0-9._/-]+' <<<"$code" | sed -E 's#^\$\{?REPO_ROOT\}?/##' | sort -u)
  fi
  # A basename counts where it can name the file. A shared basename (README.md, SKILL.md) is
  # matched as `<parent dir>/<name>` (_test_pick_path_named). For any other, dropped first:
  # comments (_test_pick_uncomment) and @test titles (prose), `stub <name>` and the fake's own quoted body (a fake
  # stands in for it), `<name>/` (a directory of that name, such as ~/.config/agentctl/), a path
  # in another directory that ends in it (_test_pick_otherdir) and
  # `<name>@` (a systemd unit). Without these, unit/fleet_dispatch.bats, a third of the unit tier,
  # was picked by 33 of 40 commits on main, and `stub store-sync 'echo "store-sync $*" >>calls.log'`
  # picked every fleet_dispatch*.bats file on a store-sync change (ar-3036).
  [ -n "$_TEST_PICK_PATHS" ] && _test_pick_path_named "$1" "$text" && return 0
  [ -n "$_TEST_PICK_WORDS" ] && grep -qE "$_TEST_PICK_WORDS" \
    <(_test_pick_unstub <<<"$text" | _test_pick_uncomment | _test_pick_otherdir | sed -E 's/^@test[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"')//
      s/(^|[[:space:];&|(])stub[[:space:]]+[^[:space:]]+/\1stub/g; s#[A-Za-z0-9._-]+[/@]#/#g') && return 0
  # A fixture is data for the tests that name it, so a change under tests/fixtures/<top> picks
  # those, not the whole tier: a comms-lint fixture ran every file of both tiers (#3040, 6.3 min).
  # basic, which sandbox_init seeds by default, is the harness above.
  [ -n "$_TEST_PICK_FIXTURES" ] && grep -qE "$_TEST_PICK_FIXTURES" <<<"$text" && return 0
  # Every ancestor directory of a changed path, regex-escaped, as one alternation; a caller
  # loops over every test file with one change list, so it is built once per list.
  if [ "${_TEST_PICK_FOR-}" != "$1" ]; then
    _TEST_PICK_FOR="$1"
    _TEST_PICK_DIRS="$(awk -F/ '{p=$1; for (i=2; i<=NF; i++) {if (!(p in s)) {s[p]; e=p
          gsub(/[][\\.*^$+?(){}|]/, "\\\\&", e); o=o (o==""?"":"|") e}; p=p "/" $i}}
          END {printf "%s", o}' <<<"$1")"
  fi
  [ -n "$_TEST_PICK_DIRS" ] || return 1
  # A reference starts the path or follows a root: `$VAR/`, `"$VAR"/`, `${VAR}/`, `~/`, `./`,
  # `../` or `$(...)/`; after any other `/` it is a deeper directory of the same name
  # (`.local/src/docs/` is not `docs/`). After the slash comes `*`, a quote, a space, `)`, `;`
  # or the line end, so `<dir>/<file>` is a path to one file, not to the directory.
  local start='(^|[^A-Za-z0-9._/-]|(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?|~|\.\.?|\))/)'
  local after='($|[*"'"'"'[:space:]);])'
  grep -qE "$start($_TEST_PICK_DIRS)/$after" <<<"$text$side"
}
