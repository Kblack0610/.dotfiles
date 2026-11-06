# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# langfuse.sh - the one push to Langfuse's ingestion API. session-outcomes sends its session
# scores and the judge lanes' verdict scores through it. Scores in Langfuse are a view: the
# rows they come from stay canonical, so a failed push is retried by the caller's mark.

LF_BATCH=100   # events per ingestion request

# lf_ingest <curl> <url> <key> <events file> <workdir>: post the events (one JSON event per
# line) in batches. Sets LF_SENT to the events Langfuse accepted and LF_STATUS to the last HTTP
# code. Returns 1 at the first batch it did not take whole (a 207 carrying per-event errors
# counts), with the reason on stderr.
lf_ingest() {
  local curl="$1" url="$2" key="$3" events="$4" work="$5" batch n=0
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
    # 207 is the normal answer: per-event results, any of which can be an error.
    if { [ "$LF_STATUS" = 200 ] || [ "$LF_STATUS" = 207 ]; } \
       && [ "$(jq '.errors | length' "$work/lf.resp" 2>/dev/null)" = 0 ]; then
      LF_SENT=$((LF_SENT + $(jq '.batch | length' "$work/lf.body")))
    else
      echo "langfuse: batch $n failed (HTTP $LF_STATUS): $(head -c 300 "$work/lf.resp" "$work/lf.err" 2>/dev/null)" >&2
      return 1
    fi
  done < "$work/lf.batches"
}
