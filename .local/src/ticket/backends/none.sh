#!/usr/bin/env bash
# none backend — explicit "no tracker" sentinel.
#
# Use as trackers.default (or a per-project system) when a repo should NOT be
# wired to any ticketing system. `system` prints `none`; every mutating verb
# exits non-zero so the kb flow degrades to `Ticket: none — <reason>`.

tb_pr_line()      { echo "Ticket: none"; }
tb_resolve_epic() { die "no tracker configured for this repo"; }
tb_claim()        { die "no tracker configured for this repo"; }
tb_create()       { die "no tracker configured for this repo"; }
tb_done()         { return 0; }
