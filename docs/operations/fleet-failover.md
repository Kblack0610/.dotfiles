# fleet-failover

The fleet keeps running when the machine that holds the fleet lease is lost. The lease design is `fleet-lease` (a branch `lease/fleet` on the store, TTL 300 s, renewed each minute; its section "The fleet lease" is in the private overlay's `QUEUE.md`). This page is how to tell a peer can take it, what to do when one cannot, and how to prove it by drill. Plan: `how-do-we-fully-twinkling-wirth` (epic ar-5278), P2.

## Which peers can take it

- Every machine runs `fleet-node publish` every 10 minutes (`fleet-node-publish.timer`). It writes `lease-ready/<host>` in the store: whether the machine may hold the lease (no `.sync/no-lease` marker) and what `fleet-node ready` found lacking. The store carries it to every peer, so any holder can count the others, the workstation included. An unchanged record is rewritten every 30 minutes, which is its proof of life.
- `fleet-node peers` reads those records: one line per machine, then `N lease-ready of M peers`. Exit 1 under 2 (`FLEET_LEASE_MIN_READY`). A machine silent for 90 minutes is not counted. `fleet-node peers --names` prints only the lease-ready ones.
- The Sentinel watch `fleet-lease-peers` runs `fleet-node peers` every 15 minutes and pages high when fewer than two machines are lease-ready, so the fleet never drifts back to one possible holder without anyone seeing it. Watches are runtime state in `~/.agent/watches/`, not in this repo: `watch-companion-loop list fleet-lease-peers` says whether it is armed.

## Losing a machine

No session is touched: a session needs no lease, and its Stop hook pushes to the store whoever holds it. What pauses is the singleton lanes (dispatch, shepherd, Sentinel, agent-web, briefing, dream, ask delivery, schedules-sync). In the drill the stepping-out holder stops them at once; after a real loss they stop when the lease lapses. Either way the taker starts them within the TTL and a minute.

1. The lease lapses 300 s after the holder's last renew. A lease-ready peer's `fleet-lease.timer` takes it within the next minute, starts agent-web, and `agent-web-record` points the agents Endpoints at it. Dispatch runs its next pass there.
2. Check: `fleet-lease status` on any peer names the holder; `fleet-dispatch hosts` prints it first and each worker's state; agent-web answers at its record.
3. Nobody takes it within about 7 minutes: run `fleet-node peers`. A peer that is not ready names its first lack; fix that on the peer (`fleet-node ready` lists every need, `fleet-node signin` the sign-ins only the human can do). A peer with `no-lease` and `fleet_lease: true` in the home-config inventory means the fleet-worker play has not run there.
4. Both remotes unreachable: no peer can tell, so none takes it (`fleet-lease` exits 2 and systemd skips the singletons). Restore the store remote first; it is forge-primary, with the GitHub backup.
5. The machine comes back: it rejoins as a candidate and does not take the lease back while the holder renews. Leave it; no machine is the home.

## The drill

`fleet-failover-drill` on the holder runs the whole thing, both ways, and prints PASS or FAIL for each step:

1. Preconditions, each a refusal: this machine holds the lease; the taker (`--taker`, else the first other lease-ready peer) is lease-ready and in the fleet roster; no `agent-land` is running. `--dry-run` stops here.
2. The holder writes `.sync/no-lease` and the lease lapses; the taker must hold it within 7 minutes.
3. On the taker: its own gate says it holds the lease, a dispatch pass ran after the step-out (`hosts.json` newer than it), every address the agents Endpoints name is the taker's, and a test page leaves it (`agent-notify -p low`; confirm it on the phone).
4. The taker writes its own marker and this machine takes the lease back, the second failover.
5. Any exit removes each marker the script wrote, so a failed drill leaves the lease free to be taken, never held by a peer that cannot hold it.

Run it only when `fleet-dispatch hosts` shows the taker placed and ready and no landing train is mid-merge. Dispatch pauses for about one TTL at each handoff. Record the run's output in the plan's Results.

Negative control: `tests/unit/fleet_node.bats` ("peers trips when a peer's ready check fails") and `tests/unit/fleet_failover_drill.bats` ("a taker that never takes the lease fails the drill") hold both directions in CI. Live, a peer whose ready check fails reads `not ready: <need>` in `fleet-node peers`, and the watch pages.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `fleet-node peers` lists a machine as `no report for N minutes` | its `fleet-node-publish.timer` is not enabled (the unit is stowed but never started), the machine is off, or its store sync is stuck | `systemctl --user enable --now fleet-node-publish.timer` on it; then `store-sync-age --peers` |
| `fleet-node peers` lists a machine as `never holds the lease` that should | `.sync/no-lease` exists: the home-config fleet-worker play writes it unless `fleet_lease` is true and `~/.notes` syncs | fix the cause the play reports; do not delete the marker by hand |
| The drill refuses with `does not hold the lease` | it was run on a peer that is not the holder | run it on the holder `fleet-lease status` names |
| The drill fails at `did not take the lease` | the taker's timer is not running, or it is not a candidate on the store | the taker's `fleet-lease status --json` (`candidate`), `systemctl --user status fleet-lease.timer` |
