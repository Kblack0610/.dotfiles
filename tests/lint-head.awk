# lint-head.awk FILE -> "<line>:<text>" for each pipeline in FILE where any command (a binary, a
# builtin like printf or compgen, a shell function) pipes into head: tests/lint.sh house rule 3,
# which runs this on the scripts that set pipefail. The hazard is head closing the pipe, not which
# command writes into it, so there is no producer list (ar-2499). tests/unit/lint_head.bats pins
# what it flags and what it passes.
#
# Each line is scanned for shell quoting so the match sees only code: single-quoted and
# double-quoted text is blanked, a $(...) inside double quotes stays code, and comments and
# heredoc bodies are dropped. So a `|` inside a jq, awk or sed program
# (`jq 'select(.a | .b) | .c' | head -1`) or a grep alternation ("a|b") does not hide the pipe
# after it. A pipeline is joined across lines while a quote or $( is open, or after a trailing `\`
# or `|`, and is reported at its first line. JOIN_MAX bounds a join, so a quote the scanner
# misreads blinds it for a few lines, never the rest of the file. With -v SPANS=1 it prints each
# join that hit the bound instead, which is how to find a misread.
BEGIN { JOIN_MAX = 400 }

function pop() { ST = substr(ST, 1, length(ST) - 1) }
# scan(s): s with quoted text blanked to '' or "", given and leaving the open quotes in ST
# (s single, a $'...', d double, c a $( ), innermost last).
function scan(s,    i, c, t, n, out) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1); t = substr(ST, length(ST), 1)
    if (t == "s") { if (c == "'") pop(); continue }
    if (t == "a") { if (c == "\\") i++; else if (c == "'") pop(); continue }
    if (t == "d") {
      if (c == "\\") i++
      else if (c == "\"") { pop(); out = out "\"\"" }
      else if (c == "$" && substr(s, i + 1, 1) == "(") { ST = ST "c"; out = out "$("; i++ }
      continue
    }
    if (c == "\\") { out = out substr(s, i, 2); i++; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];|&(]/)) break
    if (c == "'") { ST = ST (substr(s, i - 1, 1) == "$" ? "a" : "s"); out = out "''"; continue }
    if (c == "\"") { ST = ST "d"; continue }
    if (c == "$" && substr(s, i + 1, 1) == "(") { ST = ST "c"; out = out "$("; i++; continue }
    if (c == ")" && t == "c") pop()
    out = out c
  }
  return out
}

# A case arm's pattern list (`repo | head)`, at the start of the code or after `in`, `;;`, `;&`) is
# alternation, not a pipe, so it is blanked before the match; `[^();]*` keeps a subshell or $( out.
function flush() {
  gsub(/(^|[[:space:];])(in|;;&?|;&)[[:space:]]+[^();]*\)/, " ", code)
  sub(/^[[:space:]]*[^();]*\)/, " ", code)
  if (code ~ /[^|]\|[[:space:]]*head([^[:alnum:]_-]|$)/ && !SPANS)
    print start ":" buf
  buf = ""; code = ""; ST = ""
}

{
  if (hd != "") { if ($0 ~ ("^[[:space:]]*" hd "[[:space:]]*$")) hd = ""; next }
  if (buf == "") start = FNR
  c = scan($0)
  buf = buf (buf == "" ? "" : " ") $0
  code = code " " c
  # A heredoc's body is data: drop it, up to its terminator. The code says whether there is one (a
  # `<<` in quoted text is not), the raw line gives its word (the code blanked a quoted one).
  if (match(c, /(^|[^<])<<-?[[:space:]]*(''|""|[A-Za-z_\\])/) &&
      match($0, /(^|[^<])<<-?[[:space:]]*['"\\]?[A-Za-z_][A-Za-z0-9_]*/)) {
    hd = substr($0, RSTART, RLENGTH); sub(/^[^<]?<<-?[[:space:]]*['"\\]?/, "", hd)
    flush(); next
  }
  if (FNR - start >= JOIN_MAX) { if (SPANS) print FILENAME ":" start "-" FNR; flush(); next }
  if (ST != "" || c ~ /\\$|\|[[:space:]]*$/) next
  flush()
}
END { if (buf != "") flush(); if (SPANS && hd != "") print FILENAME ": heredoc " hd " never ends" }
