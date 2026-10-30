# shellcheck shell=bash disable=SC2034  # PROM_JQ is for the scripts that source this
# prom-textfile.sh - publish a tool's own numbers to Prometheus through node_exporter's
# textfile collector (scraped as job "workstation"). The tool that owns the data writes it on
# the trigger it already has; nothing else gathers it. The reader side is prom.sh.
#
#   . prom-textfile.sh
#   prom_textfile fleet_sessions.prom <command that prints the lines>
#
# PROM_TEXTFILE_DIR is the collector's directory, made by home-config's node-exporter-linux
# role (workstation play). Where it does not exist, on any other machine, nothing is written
# and nothing is said: publishing never fails the tool that publishes.
: "${PROM_TEXTFILE_DIR:=/var/lib/node_exporter/textfile}"

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
  local name="$1" dir="$PROM_TEXTFILE_DIR" tmp
  shift
  [ -d "$dir" ] || return 0
  tmp="$(mktemp "$dir/.$name.XXXXXX")" || return 1
  if "$@" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$dir/$name"; then return 0; fi
  rm -f "$tmp"
  return 1
}
