# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# pr-ci.sh - the one reading of a PR's statusCheckRollup, for every script that asks gh whether a
# PR is red: fleet-sessions (a live session's PR) and fleet-dispatch (a parked review item's PR,
# own_parked_pr). Prefix it to a jq filter over a PR's JSON: ci and red are defs.
#
# checks -> the rollup with each check's older runs dropped. A new run of a workflow on the same commit (a
# pull_request edit or a manual run, not a re-run attempt) is a new check suite, and the rollup keeps
# the old one beside it: platform#1551's failed `Task line` stayed next to the passing one 40s later and
# read CI red while `gh pr checks` was all green (2026-11-14). A check is its workflow plus its name, and
# only its entries from the newest Actions run (the run id in detailsUrl) count, so matrix shards that
# share a name all stay; a status or an entry with no run id is kept as it is.
# ci -> NONE, PENDING, FAIL or PASS: red only once every check has finished.
# red -> the red checks' Actions job ids, comma-separated, - for one that is not a job (fleet-sessions'
# gate_ci reads their steps for a gate-line-only red).
# shellcheck disable=SC2034  # read by the scripts that source it
CI_JQ='def red_re: "FAIL|ERROR|CANCEL|TIMED_OUT|ACTION_REQUIRED";
  def run_of: (.detailsUrl // "") | ((capture("/actions/runs/(?<r>[0-9]+)") | .r | tonumber) // null);
  def checks: .statusCheckRollup // [] | map(. + {_run: run_of})
    | (map(select(._run != null)) | group_by([.workflowName // "", .name // ""])
       | map(map(._run) as $r | .[] | select(._run == ($r | max))))
      + map(select(._run == null))
    | map(del(._run));
  def ci: checks | map(.conclusion // .state // "") as $c
  | if ($c | length) == 0 then "NONE"
    elif any($c[]; test("^$|PENDING|QUEUED|IN_PROGRESS|EXPECTED")) then "PENDING"
    elif any($c[]; test(red_re)) then "FAIL"
    else "PASS" end;
  def red: [checks | .[] | select((.conclusion // .state // "") | test(red_re))
            | ((.detailsUrl // "") | capture("/job/(?<j>[0-9]+)") | .j) // "-"]
          | if length == 0 then "-" else join(",") end;'
