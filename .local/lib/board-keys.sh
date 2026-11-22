# shellcheck shell=bash
# This file is SOURCED, never executed.
#
# board-keys.sh - the title prefixes fleet-bench keys its board rows by, one ERE.
#
#   BOARD_KEY_ERE   matches the start of a row's text (no checkbox) when fleet-bench filed it by a
#                   key. Group 1 is the key (a runner's carries the space after `is`). board_upsert
#                   finds a row by its key to refresh or reopen it; triage_retire closes the watch,
#                   alert, hold, logs and unit rows by theirs once their red is gone, and leaves the
#                   red, runner and lesson ones to board_upsert.
#
# Readers: fleet-bench and agentctl-inbox-triage, whose plain --backlog pass leaves these rows
# alone, since a rewritten prefix is a row fleet-bench can neither refresh nor close (ar-2482: 54
# rows lost theirs on 2026-11-15). A new key shape in fleet-bench is added here;
# tests/unit/fleet_bench.bats checks each shape's key. The ERE is POSIX for bash =~ and also valid
# for jq's test().

# shellcheck disable=SC2034 # read by the scripts that source this file
BOARD_KEY_ERE='^(check\(watch\): [^ ]+ tripped since|check\(alert\): [^ ]+ [^ ]+ firing|check\(red\): [^ ]+( [^ ]+)? is red|check\(lesson\): guard [0-9a-f]{8}:|fix\(hold\): [^ ]+ went red|fix\(logs\): [^ ]+ error [0-9a-f]{8}:|fix\(unit\): [^ ]+\.[a-z]+ failed|fix\(runner\): [^ ]+ is )'
