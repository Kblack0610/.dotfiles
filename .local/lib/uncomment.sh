#!/usr/bin/env bash
# uncomment.sh - uncomment: stdin to stdout without shell or YAML comments: whole comment lines,
# and the tail of a line from a `#` that starts a word outside quotes (`"issue #12" | agentctl add`
# keeps its name). A line whose quotes do not close keeps its tail. Sourced by test-pick.sh (a code
# line ending "so no pass asks fleet-bench for canaries" picked ten fleet_dispatch*.bats files for a
# fleet-bench change, #3104, ar-3036) and release-state (a `runs-on:` line's trailing note naming
# home-config flagged gungan's tests.yml as a deploy, ar-5591).
uncomment() {
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
