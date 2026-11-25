# shellcheck shell=bash
# end-reasons.sh -- why a queue item's run ended (its end_reason:), the one list every reader sources:
# agent-queue (check_end, lane_outcome), fleet-dispatch (settle_row), fleet-bench and judge-eval.
#
# END_REASONS: set by fleet-dispatch's settle_item from the harness's record (codex-rollout.jq, opencode-session.jq); a run that
# ended before settle_item recorded it gets the same reason by `agent-queue set`, beside its
# `model-lane void`, from that classifier's reviewed dry-run.
# UNRATED_ENDS: the ends that say nothing about the model (a refusal, a usage limit, a provider
# fault, a cut), so the run's outcome is filed unrated with that end as its cause (CAUSES below): no
# score counts it and no row is held by it.
# `timeout` and `stopped` rate as before. `handoff` is a run that passed its item to a fresh session to keep its
# context small (`agent-queue handoff`): the item goes on, so that end says nothing about the model either.
# `returned` is not here: only `agent-queue return` writes it (end_reason: returned on a cancelled item), so no `--end` or `set` can.
END_REASONS="refused limit provider cut handoff timeout stopped"
UNRATED_ENDS="refused limit provider cut handoff"

# unrated_end <end_reason> -- 0 when that end says nothing about the model.
unrated_end() { case " $UNRATED_ENDS " in *" ${1:-none} "*) return 0 ;; *) return 1 ;; esac; }

# unrated_json -- UNRATED_ENDS as a JSON array, for jq (--argjson, or spliced into a def).
unrated_json() { local s; printf -v s '"%s",' $UNRATED_ENDS; printf '[%s]' "${s%,}"; }

# CAUSES: why a run's outcome is what it is, filed with it (model-lane outcome --cause), so each harness:model
# pair's outcomes are counted by cause, never inferred. agent-queue's lane_outcome derives close (done ok or
# failed), cancel (done cancelled), requeue (any other requeue of a started item: by hand, a ladder run
# back) and an UNRATED_ENDS reason (its own cause); MOVE_CAUSES are the ones only the mover knows
# (`agent-queue move --cause`): fleet-dispatch's reap requeues a red PR to fix-ci, one in conflict to merge
# its base, a green one to a lander (land), a branch left with no PR to a takeover, and a lost host's run;
# trainee-reject sends a rejected diff back (reject), or a run that left no diff but said why back with that
# word (already-fixed: the code does the task already; blocked: it needs the human or access the run lacks;
# a no-diff run that says nothing is a failure, cause reject). UNRATED_CAUSES file the run unrated: a cancel,
# an already-fixed or blocked no-diff run (no model's miss), a lost
# host (the run went with the machine, as a cut does), and a land handoff: the lander merges the same green
# diff unchanged, so nothing was redone (a headless tier-3 run's --pr-only ends there by design); a pair that
# stops short of landing still shows as unrated/land in `model-lane report`'s causes.
MOVE_CAUSES="fix-ci conflict land takeover lost reject already-fixed blocked"
UNRATED_CAUSES="cancel land lost already-fixed blocked"

# unrated_cause <cause> -- 0 when a run with that cause is counted and never scored.
unrated_cause() { case " $UNRATED_CAUSES " in *" ${1:-none} "*) return 0 ;; *) return 1 ;; esac; }
