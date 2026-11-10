# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# pr-ci.sh - the one reading of a PR's statusCheckRollup, for every script that asks gh whether a
# PR is red: fleet-sessions (a live session's PR) and fleet-dispatch (a parked review item's PR,
# fix_red_pr). Prefix it to a jq filter over a PR's JSON: ci and red are defs.
#
# ci -> NONE, PENDING, FAIL or PASS: red only once every check has finished.
# red -> the red checks' Actions job ids, comma-separated, - for one that is not a job (fleet-sessions'
# gate_ci reads their steps for a gate-line-only red).
# shellcheck disable=SC2034  # read by the scripts that source it
CI_JQ='def red_re: "FAIL|ERROR|CANCEL|TIMED_OUT|ACTION_REQUIRED";
  def ci: .statusCheckRollup // [] | map(.conclusion // .state // "") as $c
  | if ($c | length) == 0 then "NONE"
    elif any($c[]; test("^$|PENDING|QUEUED|IN_PROGRESS|EXPECTED")) then "PENDING"
    elif any($c[]; test(red_re)) then "FAIL"
    else "PASS" end;
  def red: [.statusCheckRollup // [] | .[] | select((.conclusion // .state // "") | test(red_re))
            | ((.detailsUrl // "") | capture("/job/(?<j>[0-9]+)") | .j) // "-"]
          | if length == 0 then "-" else join(",") end;'
