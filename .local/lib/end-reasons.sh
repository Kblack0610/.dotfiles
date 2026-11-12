# shellcheck shell=bash
# end-reasons.sh -- why a queue item's run ended (its end_reason:), the one list every reader sources:
# agent-queue (check_end, lane_outcome), fleet-dispatch (settle_row), fleet-bench and judge-eval.
#
# END_REASONS: set by fleet-dispatch's settle_item from the rollout (codex-rollout.jq); a run that
# ended before settle_item recorded it gets the same reason by `agent-queue set`, beside its
# `model-lane void`, from that classifier's reviewed dry-run.
# UNRATED_ENDS: the ends that say nothing about the model (a refusal, a usage limit, a provider
# fault, a cut), so no outcome is filed for them, no score counts them and no row is held by them.
# `timeout` and `stopped` rate as before.
END_REASONS="refused limit provider cut timeout stopped"
UNRATED_ENDS="refused limit provider cut"

# unrated_end <end_reason> -- 0 when that end says nothing about the model.
unrated_end() { case " $UNRATED_ENDS " in *" ${1:-none} "*) return 0 ;; *) return 1 ;; esac; }

# unrated_json -- UNRATED_ENDS as a JSON array, for jq (--argjson, or spliced into a def).
unrated_json() { local s; printf -v s '"%s",' $UNRATED_ENDS; printf '[%s]' "${s%,}"; }
