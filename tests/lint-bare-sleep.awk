# lint-bare-sleep.awk FILE.bats... -> "<file>:<line>:<text>" for each bare `sleep N` run as a
# command inside an @test body: tests/lint.sh house rule 4. A fixed delay in a test is
# sleep-and-hope (the global no-sleep rule covers tests too): wait on the real event with
# wait_until, or set the clock the subject reads (`touch -d`, a backdated state file).
# tests/unit/lint_bare_sleep.bats pins what it flags and what it passes.
#
# What is NOT flagged, because none of it is a delay the test sleeps through:
#   - text inside quotes (`ed two ensure 'sleep 300'`, `pgrep -x sleep`) and comments;
#   - heredoc bodies, which are stub scripts the subject runs (a slow `df` fixture);
#   - a sleep backgrounded with `&`, which is a process fixture to signal or reap;
#   - a sleep inside a one-line or multi-line do...done loop: a bounded poll with its own
#     cadence is the permitted form when no event exists.
# Code outside an @test body (setup, helpers, teardown) is out of scope.
#
# Quotes and heredocs are tracked across lines, so a multi-line quoted string or stub script
# never reads as code. A quote the scanner misreads can blind it to the rest of that file
# only until the next @test line resets it.

# cnt(s, w): how many times the shell word w (do, done) appears in code text s.
function cnt(s, w,    n, re) {
  re = "(^|[^A-Za-z0-9_-])" w "($|[^A-Za-z0-9_-])"
  n = 0
  while (match(s, re)) { n++; s = substr(s, RSTART + RLENGTH - 1) }
  return n
}

# code(s): s with quoted text blanked and any trailing comment dropped; leaves the open quote
# in Q across lines ('' single, " double, a for $'...').
function code(s,    i, n, c, out) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (Q == "'") { if (c == "'") { Q = ""; out = out "'" }; continue }
    if (Q == "a") { if (c == "\\") i++; else if (c == "'") { Q = ""; out = out "'" }; continue }
    if (Q == "\"") { if (c == "\\") i++; else if (c == "\"") { Q = ""; out = out "\"" }; continue }
    if (c == "\\") { i++; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) break
    if (c == "'") { Q = (substr(s, i - 1, 1) == "$") ? "a" : "'"; out = out c; continue }
    if (c == "\"") { Q = "\""; out = out c; continue }
    out = out c
  }
  return out
}

FNR == 1 { Q = ""; TAG = ""; IN = 0; DEPTH = 0 }

# Inside a heredoc: nothing is code until its closing tag.
TAG != "" {
  l = $0
  if (DASH) sub(/^\t+/, "", l)
  if (l == TAG) TAG = ""
  next
}

Q == "" && /^@test / { IN = 1; DEPTH = 0 }

{
  raw = $0
  openq = Q
  cl = code(raw)
}

IN && openq == "" {
  if (match(cl, /(^|[;&|({])[[:space:]]*sleep[[:space:]]+[0-9$'"]/)) {
    prefix = substr(cl, 1, RSTART - 1)
    rest = substr(cl, RSTART + RLENGTH)
    gsub(/[0-9]*>&[0-9-]/, "", rest)
    bg = (rest ~ /(^|[^&])&([^&]|$)/)
    looped = (DEPTH + cnt(prefix, "do") - cnt(prefix, "done") > 0)
    if (!bg && !looped) {
      t = raw; sub(/^[[:space:]]+/, "", t)
      print FILENAME ":" FNR ":" t
    }
  }
  DEPTH += cnt(cl, "do") - cnt(cl, "done")
  if (DEPTH < 0) DEPTH = 0
}

# A heredoc opened on this line (a real one: the `<<` survives quote blanking, and `<<<` is a
# here-string). Its tag is read from the raw line.
openq == "" && index(cl, "<<") {
  if (match(raw, /<<-?[[:space:]]*['"\\]?[A-Za-z_][A-Za-z_0-9]*/) &&
      substr(raw, RSTART + 2, 1) != "<" && (RSTART == 1 || substr(raw, RSTART - 1, 1) != "<")) {
    h = substr(raw, RSTART, RLENGTH)
    DASH = (substr(h, 3, 1) == "-")
    sub(/^<<-?[[:space:]]*['"\\]?/, "", h)
    TAG = h
  }
}

IN && openq == "" && Q == "" && /^}/ { IN = 0; DEPTH = 0 }
