# kept.jq -- the one definition of a session row held open on the human's word: `manual`, set by the
# human, or `stay`, set by a session on the human's order to stay open (wind-down step 0, the coordinate
# skill). fleet-shepherd (KEPT_JQ) sends such a row no nudge and takes none over; fleet-bench samples it
# as held, so its STALLED minutes are not the fleet's stall (ar-5151). Whether it closes is its close
# verdict's (CLOSE_JQ in fleet-sessions). A def only: callers prepend the file's text to their program.
def kept: (.labels // []) | any(. == "manual" or . == "stay");
