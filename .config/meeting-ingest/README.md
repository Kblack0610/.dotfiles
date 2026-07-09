# meeting-ingest Phase 3 — Krisp webhook receiver (deploy runbook)

Lowest-latency post-meeting trigger: Krisp POSTs a "notes generated" webhook -> this receiver on home-k3s (public via a Traefik Ingress on a Cloudflare zone) -> publishes to the notes-sync MQTT broker -> the Mac subscriber (`com.kblack.meeting-ingest-mqtt`) runs a notes-only ingest.

**Status: authored, NOT deployed.** It exposes a public endpoint, so deploy only when the blockers below are cleared. Phases 1 (poll) and 2 (local end-trigger) already automate ingestion without any of this; Phase 3 is the latency upgrade.

## Why the split
Ingest needs the Krisp MCP session, the `notes` CLI, and the vault -- all on the laptop. The receiver cannot ingest; it only forwards a minimal event. The laptop-side subscriber re-pulls the final doc via the Krisp MCP (so an early payload that predates speaker diarization is never trusted).

## Known infra facts (verified 2026-07-08)
- **Broker:** `mosquitto.kblab.me:31883`, no auth today (the notes-sync broker). Reachable from the Mac (LAN, AdGuard DNS) and in-cluster. Receiver + subscriber both use it; topic `meeting-ingest/krisp`.
- **Registry:** `git.kblab.me` (Forgejo on home-k3s). Image `git.kblab.me/kblack/krisp-receiver:latest`.
- **Public DNS:** `*.kblab.me` is LAN-only (AdGuard) and will NOT work for an external webhook. Use a PUBLIC Cloudflare zone -> `krisp-hook.kblack.dev`. Routing is GitOps: a Traefik Ingress (ingress.yaml) pushed to the `home-config` repo; external-dns publishes the proxied CNAME and the `public-sites-homelab` tunnel wildcard routes it. Do NOT add a per-host tunnel route (obsolete; the cluster token can't edit tunnel config).

## Blockers to clear first (need you)
1. **Krisp tier + registration.** Confirm your plan includes webhooks (Business confirmed; Pro maybe): Krisp dashboard -> Settings -> Integrations -> Webhook. Registration itself is dashboard-only (no self-serve API without the tier).
2. **home-k3s kubeconfig** is not on this Mac (only the work EKS context). Merge it before any `kubectl`.
3. **docker login git.kblab.me** (Forgejo token; see `forgejo-ops`) before `docker push`.
4. **home-config repo access** for the public Ingress (GitOps), separate from this dotfiles repo.

## Deploy
```bash
# 1. build + push the receiver image
docker login git.kblab.me                      # blocker 3
docker build -t git.kblab.me/kblack/krisp-receiver:latest .config/meeting-ingest/receiver
docker push git.kblab.me/kblack/krisp-receiver:latest

# 2. namespace + webhook secret (kubeconfig from blocker 2; k8s-ops skill)
kubectl create namespace meeting-ingest
SECRET=$(openssl rand -hex 24); echo "webhook secret: $SECRET"   # save for Krisp dashboard
kubectl -n meeting-ingest create secret generic krisp-receiver --from-literal=webhook-secret="$SECRET"

# 3. deploy the receiver
kubectl apply -f .config/meeting-ingest/k8s/deployment.yaml

# 4. public route (GitOps): copy k8s/ingress.yaml into home-config/apps/krisp-receiver/
#    and push. external-dns + the tunnel wildcard do the rest. (blocker 4)

# 5. register the webhook in Krisp (blocker 1): URL https://krisp-hook.kblack.dev ,
#    event = notes/summary generated, header X-Webhook-Secret: $SECRET

# 6. arm the Mac subscriber (broker already set in the plist)
cp .config/launchd/com.kblack.meeting-ingest-mqtt.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.kblack.meeting-ingest-mqtt.plist
```

## Verify
- `kubectl -n meeting-ingest logs deploy/krisp-receiver` shows the listen line.
- Krisp test webhook (or `curl -H "X-Webhook-Secret: $SECRET" -d '{"event":"notes_generated","title":"Test","meeting_id":"..."}' https://krisp-hook.kblack.dev`) -> receiver logs "queued".
- `~/.local/state/meeting-ingest/mqtt-sub.log` shows the ingest trigger; a note appears in the vault.
- An unsigned POST returns 401.

## Files
- `receiver/receiver.py`, `receiver/Dockerfile` -- the forwarder service (listens on 8080).
- `k8s/deployment.yaml` -- Deployment + Service (namespace `meeting-ingest`), broker as plain env.
- `k8s/ingress.yaml` -- Traefik Ingress template (lives in home-config when deployed).
- `../launchd/com.kblack.meeting-ingest-mqtt.plist` -- Mac subscriber LaunchAgent (broker preset).
- `../../.local/src/meeting-status/meeting-ingest-mqtt-sub.sh` -- subscriber loop (needs `mosquitto_sub` + `jq`).
