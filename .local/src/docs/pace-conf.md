# Pace config

The pace numbers live in `.config/claude-acct/pace.conf`: claude-acct's room verdict, dispatch's pace target (`spare`) and the bulk-wake budget. That file holds the defaults. `pace-conf` lays a standing override or a time-bounded window over a key without a PR, and `pace_get` (`.local/lib/pace-conf.sh`) reads all three for every caller, in this order:

1. a window for the key that is in force now;
2. else the key's standing override;
3. else the pace.conf line.

A window beats a standing override because it is the narrower, timed value: a 300% window inside a standing 100% applies while it runs. When a window ends, the next source is back the next time anything reads the key. No timer resets it (the same read-time expiry as `machine-mode release-lane`, [machine-mode.md](machine-mode.md)).

## Use

```bash
pace-conf                                          # every key: value in force, source, default, and the schedule
pace-conf --json                                   # the same for the hub, plus each row's state
pace-conf set BURN_OVER_PCT 300 --until 'tue 22:00'           # a window from now
pace-conf set BURN_OVER_PCT 50 --from 'tomorrow 09:00' --until 'tomorrow 18:00'
pace-conf set BURN_OVER_PCT 200                    # a standing override, in place of the last one
pace-conf end BURN_OVER_PCT @1795586400            # end the window that starts then (pace-conf lists each one's)
pace-conf end BURN_OVER_PCT                        # end the standing override
```

Times are anything `date -d` reads. A key is editable only when pace.conf has a `<KEY>_MAX` line, and its value must be a number from 0 to that max: `BURN_OVER_PCT_MAX=1000` makes the burn allowance one and `WAKE_BUDGET_MAX=6` the bulk-wake batch another (raise it for a large restore after a reboot), and a later key needs only its own `_MAX` line. A key whose pace.conf default is a whole number takes only whole values. A window lasts at most `PACE_WINDOW_MAX_DAYS` (7), so a forgotten one ends by itself, and two windows of one key may not overlap. Ending a window in force ends it now, and ending one that has not started removes it.

The overrides live in `~/.agent/pace-overrides`, machine-local state, one `key|value|from|until|by` row each (epoch seconds; an empty `until` is a standing override). `by` is `agent-web` when the hub's audited route ran the command (`AGENT_AUDITED` is its pid, the test `lib/audit.sh` makes) and `hand` otherwise. Only `pace-conf` writes the file, under a lock, replacing it whole, and dropping ended windows as it writes.

`claude-acct status` names the allowance in force on its fleet line ("allowance 400% (default)", "allowance 300% to Tue 22:00"). The textfile publishes `claude_fleet_allowed_points_per_hour` (what the pool sustains times the allowance) and `claude_fleet_spare_sessions` (dispatch's pace target, which dispatch itself reads live from `claude-acct room --json`), so a surface reads them with no second formula. The allowance loosens only room's `committed` check: pace, reserve, five_hour and capped still refuse on their own.

## Where to see and set it

Costs > Limits in agent-web and the hub shows the allowance in force and where it came from, what it lets through (the fleet burn against the sustainable and allowed rates, and the spare sessions), the schedule of windows, and every pace.conf key with its value, source and default (`hub_core::pace_conf`, one read of `pace-conf --json` shared by both). The Burn headline names the allowance beside "sustainable", and the fleet is red when its burn passes the allowed rate (dispatch holds there), amber over sustainable within the allowance; one `level` field from `hub_core::pace_conf` gives both surfaces that verdict. While claude-acct's allowed figure still belongs to the allowance before the last change (more than a point off the percent in force), both surfaces say so (`lagging`). agent-web alone sets and ends: the form on the Allowance section and each row's End button post to `/api/pace/set` and `/api/pace/end`, which check the key against the editable list, the value against its maximum and the times against `@<epoch>` or `YYYY-MM-DDTHH:MM` (the page sends `@<epoch>` from its own clock, so the browser's zone decides, not the server's) before building the `pace-conf` argv, and show the CLI's own words on a refusal. The hub TUI is read-only. The page repaints when `~/.agent/pace-overrides` changes; a window that ends with no write shows as ended within the 120 seconds the Costs read is kept.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| claude-acct exits 1 with "a BURN_OVER_PCT row in ~/.agent/pace-overrides is not key\|value\|from\|until\|by" | a hand edit left a malformed row; it stops readers the way a bad pace.conf line does | `pace-conf end BURN_OVER_PCT` drops it; for a key that is not editable, delete the line |
| `pace-conf set` says "it overlaps the ... window" | windows of one key never overlap | `pace-conf end <KEY> @<from>` for the old one, then set the new one |
| The hub's spare or allowed figure lags a set or an end | those two come from the claude-acct textfile, written every 15 minutes; dispatch and room read the value in force on each call | wait for the timer (claude-acct-usage); `pace-conf` and `claude-acct status` show the new value at once |
| The Allowance section says "pace config: ..." or shows no schedule | `pace-conf --json` failed (a malformed override row, or pace.conf missing); the error is the CLI's own | run `pace-conf` by hand and fix what it names |
| `pace-conf set` says "is not editable" | the key has no `<KEY>_MAX` line in pace.conf | add the `_MAX` line by PR; the override path then carries the key with no code change |
