# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# pr-ci.sh - the one reading of a PR's statusCheckRollup, for every script that asks gh whether a
# PR is red: fleet-sessions (a live session's PR), fleet-dispatch (a parked review item's PR,
# own_parked_pr), agent-land and the Prefix+S PR board (pr-viewer.sh). Prefix it to a jq filter
# over a PR's JSON: ci and red are defs.
#
# checks -> the rollup with each check's older runs dropped. A new run of a workflow on the same commit (a
# pull_request edit or a manual run, not a re-run attempt) is a new check suite, and the rollup keeps
# the old one beside it: platform#1551's failed `Task line` stayed next to the passing one 40s later and
# read CI red while `gh pr checks` was all green (2026-11-14). A check is its workflow plus its name, and
# only its entries from the newest Actions run (the run id in detailsUrl) count, so matrix shards that
# share a name all stay; a status or an entry with no run id is kept as it is. A cancelled matrix job
# that never expanded keeps its template name (`fast (${{ matrix.n }})`), which no newer entry shares: it
# goes once an entry of a newer run of its workflow matches the template. A PR opened and pushed to in the
# same second gets two pull_request runs on one head and concurrency cancels the older (dotfiles#2437
# runs 44346646978 and 44346649779, 2026-11-18, ar-3095).
# ci -> NONE, PENDING, FAIL or PASS: red only once every check has finished.
# red -> the red checks' Actions job ids, comma-separated, - for one that is not a job (fleet-sessions'
# gate_ci reads their steps for a gate-line-only red).
# infra -> true for a FAIL that is the runners' and not the code's: every red check concluded CANCELLED
# or TIMED_OUT (a job cut at its timeout-minutes on a starved node), apart from a FAILURE that started
# only after every such check of its own run had finished, which is an aggregate reading its cancelled
# needs (dotfiles `gate`, needs: all). One other red beside them is a code red. On 2026-11-25 #3516,
# #3538 and #3576 read red with every job cancelled at ~617s on starved ARC runners, spent two fix-ci
# tries each and sat escalated with nothing to fix (fleet-dispatch own_parked_pr reruns them now).
# red_runs -> the Actions run ids of the red checks, comma-separated, - for none (what a rerun reruns).
# PR_CI_NO_VERDICT: an ERE over workflow names whose checks say nothing about the PR's own branch, left
# out of ci and red; empty: off. unity-core-playground's Drop closed gates runs on a PR's close or
# unlabel event and runs Checks again on the PRs the landing slot refused. Its jobs attach to the PR's
# head, and its concurrency group cancels the older run still queued, so PR #2870 (Checks SUCCESS
# @bcdee033) read CI FAIL and drew a false nudge (2026-11-18, ar-3499). CI_JQ reads it as $ENV.
export PR_CI_NO_VERDICT="${PR_CI_NO_VERDICT-^Drop closed gates\$}"
# REVIEW_CONTEXT: the commit status a second agent's verdict is (agent-land --verdict, validate_gate reads it), its one
# home (skip-guard reads it here too). It is a review, not CI, so ci, red and infra leave it out: a fail verdict
# would read as red Checks and draw a fix-ci session that has nothing to fix (ar-5450). CI_JQ reads it as $ENV.
export REVIEW_CONTEXT=review
# shellcheck disable=SC2034  # read by the scripts that source it
CI_JQ='def red_re: "FAIL|ERROR|CANCEL|TIMED_OUT|ACTION_REQUIRED";
  def run_of: (.detailsUrl // "") | ((capture("/actions/runs/(?<r>[0-9]+)") | .r | tonumber) // null);
  def checks: ($ENV.PR_CI_NO_VERDICT // "") as $nv | .statusCheckRollup // []
    | map(select($nv == "" or ((.workflowName // "") | test($nv) | not)) | select(.context == null or .context != $ENV.REVIEW_CONTEXT)
      | . + {_run: run_of})
    | (map(select(._run != null)) | group_by([.workflowName // "", .name // ""])
       | map(map(._run) as $r | .[] | select(._run == ($r | max))))
      + map(select(._run == null))
    | . as $all
    | map(select(. as $e | if $e._run != null and ($e.conclusion // "" | test("CANCEL")) and ($e.name // "" | test("[$][{][{]"))
        then ("^" + ($e.name | gsub("[$][{][{][^}]*[}][}]"; "\u0001") | gsub("(?<c>[.*+?()\\[\\]{}|^$\\\\])"; "\\\(.c)")
          | gsub("\u0001"; ".+")) + "$") as $re
          | $all | any(.workflowName == $e.workflowName and (._run // 0) > $e._run and (.name // "" | test($re))) | not
        else true end))
    | map(del(._run));
  def ci: checks | map(.conclusion // .state // "") as $c
  | if ($c | length) == 0 then "NONE"
    elif any($c[]; test("^$|PENDING|QUEUED|IN_PROGRESS|EXPECTED")) then "PENDING"
    elif any($c[]; test(red_re)) then "FAIL"
    else "PASS" end;
  def red: [checks | .[] | select((.conclusion // .state // "") | test(red_re))
            | ((.detailsUrl // "") | capture("/job/(?<j>[0-9]+)") | .j) // "-"]
          | if length == 0 then "-" else join(",") end;
  def infra: ci == "FAIL" and ([checks[] | . + {_run: run_of, _c: (.conclusion // .state // "")} | select(._c | test(red_re))] as $r
    | ($r | map(select(._c | test("CANCEL|TIMED_OUT")))) as $cut
    | ($cut | length) > 0
      and all($r[] | select(._c | test("CANCEL|TIMED_OUT") | not); . as $f
        | ($cut | map(select($f._run != null and ._run == $f._run))) as $mine
        | ($mine | length) > 0 and ($f.startedAt // "") >= ($mine | map(.completedAt // "~") | max)));
  def red_runs: [checks[] | select((.conclusion // .state // "") | test(red_re)) | run_of | select(. != null) | tostring]
          | unique | if length == 0 then "-" else join(",") end;'
