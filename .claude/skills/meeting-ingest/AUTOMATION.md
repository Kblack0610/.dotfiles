# meeting-ingest — post-meeting automation

Three layers, each lower-latency than the last, mirroring the notes-sync stack (MQTT push + WatchPaths + StartInterval fallback). All layers converge on the same ingest and are made idempotent by the dedup ledger (`~/.local/state/meeting-ingest/ingested.tsv`), so running several at once is safe. All are **notes-only**: they write the meeting note (and a `## Suggested Tickets` block) but never create tracker tickets -- that stays interactive via `/meeting-ingest`.

```
              latency        cooperation needed        where
 Phase 1  poll   ~30 min    none                        laptop (launchd / agentctl)
 Phase 2  local  ~end+10m   macOS Calendar + mic         Mac (launchd WatchPaths)
 Phase 3  push   ~minutes   Krisp Business webhook       cluster receiver -> MQTT -> Mac
```

Ingest needs the Krisp MCP, so every layer drives the `claude --print` harness (the only MCP-capable one). Run automation on the machine whose `notes` profile matches the meetings you want captured (work meetings -> the Mac).

---

## Phase 1 -- safety poll (guaranteed catch)

The backstop. Dedup-guarded, ~30 min.

**macOS (launchd):**
```bash
cp ~/.dotfiles/.config/launchd/com.kblack.meeting-ingest.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.kblack.meeting-ingest.plist   # arm
launchctl unload -w ~/Library/LaunchAgents/com.kblack.meeting-ingest.plist # disarm
```

**Linux (agentctl):**
```bash
mv ~/.dotfiles/.config/agentctl/agents/meeting-ingest.conf{.disabled,} && agentctl reload   # arm
mv ~/.dotfiles/.config/agentctl/agents/meeting-ingest.conf{,.disabled} && agentctl reload    # disarm
```

---

## Phase 2 -- local end-trigger (macOS only)

Fires `meeting-end-trigger.sh` right after a meeting you actually attended. Reuses the signals the sketchybar/EventKit layer already computes: `~/.local/cache/sketchybar/calendar.state` (start/end/rsvp/title), `mic-active` (in-call), and the `joined.<start>` latch. The launchd agent runs it on every calendar-cache change (`WatchPaths`) and every 5 min (`StartInterval`, so end+grace is still checked when nothing writes the cache). The script captures attended meetings while they are live (the sketchybar layer deletes the joined latch the moment the meeting flips), then dispatches once end + a 10-min grace passes (Krisp processing lag). Idempotent via per-meeting dedup markers.

```bash
cp ~/.dotfiles/.config/launchd/com.kblack.meeting-ingest-watch.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.kblack.meeting-ingest-watch.plist   # arm
launchctl unload -w ~/Library/LaunchAgents/com.kblack.meeting-ingest-watch.plist # disarm
```

Tunables (env, or edit the plist ProgramArguments): `MEETING_INGEST_GRACE` (secs after end before dispatch, default 600). Logs: `~/.local/state/meeting-ingest/trigger.log`, `/tmp/meeting-ingest-watch.*.log`.

Prereq: SketchyBar Calendar access must already be granted (the bar's meeting item works), since this reads the cache it writes.

---

## Phase 3 -- Krisp native webhook (lowest latency; needs Business tier)

Krisp POSTs a "notes generated" event -> a small receiver on home-k3s (behind a Cloudflare tunnel) -> publishes to the MQTT bus -> a Mac subscriber runs the ingest. Subscribe to the **notes/summary-generated** event, NOT raw transcript, to avoid Krisp's documented unnamed-speaker race (early transcript events arrive before diarization names people).

Templates live in `~/.dotfiles/.config/meeting-ingest/` (receiver + k8s manifests + subscriber plist + README). **Deploy only after** confirming the prereqs below -- this exposes a public endpoint, so it is gated on an explicit go-ahead.

Prereqs / blockers (see the README for the full runbook):
1. Krisp tier includes webhooks (Business confirmed; Pro maybe) -- verify in Krisp dashboard -> Settings -> Integrations -> Webhook. Registration is dashboard-only.
2. home-k3s kubeconfig merged onto the Mac (only the work EKS context is present today).
3. `docker login git.kblab.me` (Forgejo) before pushing the image.
4. The public host is `krisp-hook.kblack.dev` (a PUBLIC Cloudflare zone) via a Traefik Ingress pushed to the `home-config` GitOps repo -- NOT `*.kblab.me` (LAN-only AdGuard) and NOT a per-host tunnel route (obsolete). Broker is the notes-sync `mosquitto.kblab.me:31883` (no auth today).

Deploy outline (concrete commands in `~/.dotfiles/.config/meeting-ingest/README.md`): build+push image -> apply the Deployment/Service -> push the Ingress via home-config -> register the webhook URL + secret in Krisp -> load the Mac subscriber LaunchAgent. Verify with a Krisp test webhook end-to-end.

---

## Notes
- Headless `claude --print` needs the Krisp MCP configured for that harness and Anthropic credit available (the agentctl README "credit too low" note applies to premium models via the gateway).
- `date -r <epoch>` in the trigger is BSD/macOS semantics; the trigger is macOS-only by design (Linux uses the Phase 1 agentctl poll).
- launchd plists here are copy-and-load (not stow-symlinked), matching the notes-sync / bose-audio-guard convention.
