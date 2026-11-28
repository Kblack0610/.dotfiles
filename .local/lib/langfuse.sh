# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# langfuse.sh - the one push to Langfuse's ingestion API. session-outcomes sends its session
# scores and the judge lanes' verdict scores through it. Scores in Langfuse are a view: the
# rows they come from stay canonical, so a failed push is retried by the caller's mark.

LF_BATCH=100   # events per ingestion request

# lf_ingest <curl> <url> <key> <events file> <workdir>: post the events (one JSON event per
# line) in batches. Sets LF_SENT to the events Langfuse accepted and LF_STATUS to the HTTP code
# of the first batch not taken whole (else the last). Returns 1 when any event was not taken,
# with the reason on stderr. A batch Langfuse answered with per-event errors (a 207) took the
# rest, so the next batch still goes: one bad event never stops the others being sent. The
# caller's mark still holds, so the rejected event is retried and stays on stderr until its
# builder is fixed. A batch Langfuse did not answer stops the push there.
lf_ingest() {
  local curl="$1" url="$2" key="$3" events="$4" work="$5" batch n=0 total rejected failed=""
  LF_SENT=0 LF_STATUS=""
  jq -cn --argjson b "$LF_BATCH" '[inputs] | range(0; length; $b) as $i | {batch: .[$i:$i + $b]}' \
    < "$events" > "$work/lf.batches" || { echo "langfuse: could not batch the events" >&2; return 1; }
  while IFS= read -r batch; do
    n=$((n + 1))
    printf '%s' "$batch" > "$work/lf.body"
    # The key goes in on stdin (-K -), never argv, where any `ps` would show it.
    LF_STATUS="$(printf 'user = "%s"\n' "$key" | "$curl" -sS -K - -o "$work/lf.resp" -w '%{http_code}' \
      --max-time 30 -H 'Content-Type: application/json' \
      --data-binary @"$work/lf.body" "$url/api/public/ingestion" 2>"$work/lf.err")" || LF_STATUS=000
    rejected="$(jq '.errors | length' "$work/lf.resp" 2>/dev/null)" || rejected=""
    # 207 is the normal answer: per-event results, any of which can be an error.
    if { [ "$LF_STATUS" = 200 ] || [ "$LF_STATUS" = 207 ]; } && [[ "$rejected" =~ ^[0-9]+$ ]]; then
      total="$(jq '.batch | length' "$work/lf.body")"
      LF_SENT=$((LF_SENT + total - rejected))
      [ "$rejected" = 0 ] && continue
      failed="${failed:-$LF_STATUS}"
      # The first rejection's id, message and the field its schema check names (`error` is the
      # issue list, sent as a JSON string today).
      echo "langfuse: batch $n: $rejected of $total event(s) rejected (HTTP $LF_STATUS), first: $(jq -r '.errors[0]
        | "\(.id) \(.status // "") \(.message // ""), field \(((.error | if type == "string" then fromjson else . end
            | .[0].path | map(tostring) | join("."))? // "?"))"' "$work/lf.resp" 2>/dev/null)" >&2
    else
      echo "langfuse: batch $n failed (HTTP $LF_STATUS): $(head -c 300 "$work/lf.resp" "$work/lf.err" 2>/dev/null)" >&2
      return 1
    fi
  done < "$work/lf.batches"
  [ -z "$failed" ] || { LF_STATUS="$failed"; return 1; }
}

# lf_delete <curl> <url> <key> <ids file> <workdir>: delete each score id (one per line) via
# DELETE /api/public/scores/<id>. Any 2xx is a deletion (Langfuse answers 202, "Score deletion
# queued successfully"); 404 is treated as already absent. Sets LF_DELETED to the count of 2xx
# deletions and LF_STATUS to the last HTTP code. Returns 1 on any other code.
lf_delete() {
  local curl="$1" url="$2" key="$3" ids="$4" work="$5" id code
  LF_DELETED=0 LF_STATUS=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    : > "$work/lf.del.resp"
    code="$(printf 'user = "%s"\n' "$key" | "$curl" -sS -K - -X DELETE -o "$work/lf.del.resp" -w '%{http_code}' \
      --max-time 30 "$url/api/public/scores/$id" 2>"$work/lf.del.err")" || code=000
    LF_STATUS="$code"
    if [[ "$code" == 2[0-9][0-9] ]]; then
      LF_DELETED=$((LF_DELETED + 1))
    elif [ "$code" != 404 ]; then
      echo "langfuse: delete $id failed (HTTP $code): $(head -c 300 "$work/lf.del.resp" "$work/lf.del.err" 2>/dev/null)" >&2
      return 1
    fi
  done < "$ids"
}
