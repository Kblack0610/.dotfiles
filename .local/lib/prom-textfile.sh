# shellcheck shell=bash disable=SC2034  # PROM_JQ is for the scripts that source this
# prom-textfile.sh - publish a tool's own numbers to Prometheus through node_exporter's
# textfile collector (scraped as job "workstation"). The tool that owns the data writes it on
# the trigger it already has; nothing else gathers it. The reader side is prom.sh.
#
#   . prom-textfile.sh
#   prom_textfile fleet_sessions.prom <command that prints the lines>
#
# PROM_TEXTFILE_DIR is the collector's directory. The workstation's node_exporter reads
# /var/lib/node_exporter/textfile (home-config's node-exporter-linux role); the DaemonSet on a
# k3s node reads /var/lib/node-exporter-textfile (its node-disk-metrics role, helm-values.yaml).
# A machine has one of them, so the first of PROM_TEXTFILE_DIRS that exists is the collector's.
# Where none exists, nothing is written and nothing is said: publishing never fails the tool
# that publishes.
: "${PROM_TEXTFILE_DIRS:=/var/lib/node_exporter/textfile:/var/lib/node-exporter-textfile}"   # PATH-style
prom_textfile_default_dir() {
  local d dirs
  IFS=: read -ra dirs <<< "$PROM_TEXTFILE_DIRS"
  for d in "${dirs[@]}"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  printf '%s\n' "${dirs[0]}"
}
: "${PROM_TEXTFILE_DIR:=$(prom_textfile_default_dir)}"

# prom_textfile_target [dir]: where a tool that takes an optional dir publishes. A given dir is
# used as is; otherwise PROM_TEXTFILE_DIR, and status 1 with no output when this machine has no
# collector (the caller skips, as the unit's old ConditionPathIsDirectory did).
prom_textfile_target() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return 0; fi
  [ -d "$PROM_TEXTFILE_DIR" ] || return 1
  printf '%s\n' "$PROM_TEXTFILE_DIR"
}

# jq defs the writers build their lines with:
#   lbl                          a label value escaped per the exposition format
#   gauge($name; $help; series)  HELP and TYPE, then one line per [labels, value] pair that
#                                series yields; a null value drops that series rather than
#                                writing a guessed 0, and a boolean is written 1 or 0
PROM_JQ='
def lbl: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
def labels: to_entries | map("\(.key)=\"\(.value | lbl)\"") | join(",") | if . == "" then "" else "{\(.)}" end;
def gauge($name; $help; series):
  "# HELP \($name) \($help)", "# TYPE \($name) gauge",
  (series | select(.[1] != null)
   | "\($name)\(.[0] | labels) \(.[1] | if type == "boolean" then (if . then 1 else 0 end) else . end)");
'

# prom_textfile <name> <command...>: run the command and publish its stdout as <name>. It is
# written to a temp file in the same directory and renamed, so a scrape never reads half a
# file, and a command that fails leaves the last good file in place. The temp name does not
# end in .prom, so the collector never reads it.
prom_textfile() {
  local name="$1" dir tmp
  shift
  dir="$(prom_textfile_target)" || return 0
  tmp="$(mktemp "$dir/.$name.XXXXXX")" || return 1
  if "$@" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$dir/$name"; then return 0; fi
  rm -f "$tmp"
  return 1
}
