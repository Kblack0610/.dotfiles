#!/usr/bin/env bats
# .local/lib/stat.sh is the one GNU-then-BSD stat fallback (ar-4498). CI runs GNU stat, so the BSD
# forms are checked against a stub that refuses -c, as BSD stat does.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$BATS_TEST_TMPDIR/f"; : > "$F"; chmod 640 "$F"; touch -d @1700000000 "$F"
  BSD="$BATS_TEST_TMPDIR/bsd"; mkdir -p "$BSD"
  # BSD stat: -f <fmt> -- <path>; %m mtime, %d device, %Lp permission bits. A -c is an unknown flag.
  GNU_STAT="$(command -v stat)"
  { echo '#!/usr/bin/env bash'; printf 'gnu=%q\n' "$GNU_STAT"; cat <<'STUB'
[ "$1" = -f ] || { echo "stat: illegal option -- ${1#-}" >&2; exit 1; }
p="$4"; [ -e "$p" ] || { echo "stat: $p: stat: No such file or directory" >&2; exit 1; }
case "$2" in
  %m) "$gnu" -c %Y -- "$p" ;;
  %d) "$gnu" -c %d -- "$p" ;;
  %Lp) "$gnu" -c %a -- "$p" ;;
  *) exit 1 ;;
esac
STUB
  } > "$BSD/stat"
  chmod +x "$BSD/stat"
}

@test "GNU stat: mtime, device and mode of a path" {
  run bash -c '. "$1"; stat_mtime "$2"; stat_mode "$2"; [ "$(stat_dev "$2")" = "$(stat -c %d -- "$2")" ] && echo dev' _ "$ROOT/.local/lib/stat.sh" "$F"
  [ "$status" -eq 0 ]
  [ "$output" = $'1700000000\n640\ndev' ]
}

@test "BSD stat: the same three values through -f, when -c is refused" {
  # the stub answers through the real stat by its full path, so only the helpers see the BSD form
  run env PATH="$BSD:$PATH" bash -c '. "$1"; stat_mtime "$2"; stat_mode "$2"; stat_dev "$2"' _ "$ROOT/.local/lib/stat.sh" "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '1700000000\n640\n%s' "$(stat -c %d -- "$F")")" ]
}

@test "a gone path prints nothing and fails, on either stat" {
  run bash -c '. "$1"; stat_mtime "$2"' _ "$ROOT/.local/lib/stat.sh" "$BATS_TEST_TMPDIR/gone"
  [ "$status" -ne 0 ]; [ -z "$output" ]
  run env PATH="$BSD:$PATH" bash -c '. "$1"; stat_mode "$2"' _ "$ROOT/.local/lib/stat.sh" "$BATS_TEST_TMPDIR/gone"
  [ "$status" -ne 0 ]; [ -z "$output" ]
}
