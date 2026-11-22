# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# board-keys.sh - the title prefixes fleet-bench keys its agent-board rows by, one ERE.
#
#   BOARD_KEY_ERE   matches the start of a row's text (no checkbox) when fleet-bench filed it by a
#                   key: board_upsert finds its row by that prefix to refresh or reopen it, and
#                   triage_retire to close it. Group 1 is the key (a runner's carries the space
#                   after `is`), and it is the only group.
#
# Readers: fleet-bench (board_upsert's keys, triage_retire) and agentctl-inbox-triage, whose
# --backlog rewrite leaves these rows alone, since a rewritten prefix is a row fleet-bench can
# neither refresh nor close (ar-2482: 54 rows lost theirs on 2026-11-15). A new key shape in
# fleet-bench is added here, and tests/unit/fleet_bench.bats checks each shape it files matches.
# The ERE is POSIX for bash =~ and also valid for jq's test().

# shellcheck disable=SC2034 # read by the scripts that source this file
BOARD_KEY_ERE='^(check\(watch\): [^ ]+ tripped since|check\(alert\): [^ ]+ [^ ]+ firing|check\(lesson\): guard [0-9a-f]{8}:|fix\(hold\): [^ ]+ went red|fix\(logs\): [^ ]+ error [0-9a-f]{8}:|fix\(unit\): [^ ]+ failed|fix\(runner\): [^ ]+ is )'
