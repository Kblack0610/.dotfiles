# meeting-notes

Glue between a local meeting recorder and this machine's Claude + mem0 stack. Part of the
cross-environment meeting-notes setup (plan: `~/.claude/plans/fathom-is-a-fantastic-streamed-lantern.md`).

Two tracks:

- **Mac / Windows VDI / mobile → Krisp** (already provided; bot-free local capture). Krisp has no
  API/MCP, so its meetings reach mem0 via the Krisp→mem0 bridge below. (Alternative: Fellow.ai —
  has an MCP connector but a visible bot; see end.)
- **Private / in-person meetings on Linux → HushNote → this bridge → mem0 + Claude.**

Both tracks funnel into mem0 through one payload contract (`meeting_mem0.py`).

## What's in here

| File | Role |
|---|---|
| `meeting_mem0.py` | **Single source of truth** for the mem0 POST (payload + `push_memory()`): `infer:false`, `agent_id=meetings`, per-meeting `run_id`, `metadata.{source,title,timestamp}`. Used by the CLI + webhook. |
| `meeting-note-mem0` | Universal CLI: read a note (file/stdin) + `--title/--date/--source/--run-id`, push to mem0. For cron pollers, exports, or manual use. Symlinked to `~/.local/bin/meeting-note-mem0`. |
| `krisp-mem0-webhook.py` | HTTP receiver for Krisp notes relayed by Zapier (behind a Tailscale Funnel). Shared-secret auth; `POST /krisp`. |
| `hushnote-mem0-hook.sh` | HushNote `POST_SUMMARY_HOOK` target (bash; reads summary + sibling `*_metadata.json`). Symlinked to `~/.local/bin/hushnote-mem0-hook`. (Predates `meeting_mem0.py`; same payload shape — could later just call the CLI.) |
| `hushnoterc.sample` | Recommended HushNote settings for this machine (Whisper/Ollama/hook). |
| `README.md` | This file. |

## Linux pipeline

```
hushnote full          # record → compress → trim → transcribe → summarize → POST_SUMMARY_HOOK
   → ~/meeting-notes/<date>/meeting_<ts>/{*.txt, *_summary.md, *_metadata.json}
   → hushnote-mem0-hook pushes *_summary.md to mem0.kblab.me/memories
   → recall via the mem0-ops skill, or browse the markdown directly in Claude
```

### Install HushNote (one-time, run by you)

HushNote is third-party (`peteonrails/hushnote`, MIT, alpha) — keep it out of the dotfiles tree:

```bash
git clone https://github.com/peteonrails/hushnote ~/dev/hushnote
cd ~/dev/hushnote
# system deps (sudo): yay -S ffmpeg pipewire-pulse python
python -m venv venv
./venv/bin/pip install -e '.[diarize]'        # drop [diarize] to skip pyannote
./venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cu121
# Ollama is already present on this box; ensure the summary model is pulled:
ollama pull qwen2.5:14b
cp .hushnoterc.example .hushnoterc             # then merge in lines from hushnoterc.sample here
```

Smoke-test: `./hushnote full -d 30 -t "test"` → confirm a summary lands under `~/meeting-notes/`
and (once mem0 is up) the hook log shows `OK 2xx`.

### Claude access to the notes (B4)

Simplest: point the already-configured filesystem MCP at `~/meeting-notes/` so Claude can
read/@-mention meeting markdown. A richer custom MCP server (search/synthesize/push tools) is
optional — see the plan. Not wired yet.

## mem0 bridge details

- Endpoint: `POST $MEM0_BASE_URL/memories` (`MEM0_BASE_URL` default `https://mem0.kblab.me`;
  unprefixed routes, LAN/Tailscale only). Auth currently disabled server-side; set `MEM0_API_KEY`
  when it flips on. Mirrors the `mem0-ops` skill.
- Stores the summary verbatim (`infer:false`), scoped `user_id=kblack0610`, `agent_id=meetings`,
  `run_id=<meeting dir name>`, with `metadata.{title,timestamp,source:hushnote,meeting}`.
- Exit 0 on 2xx (HushNote writes `.hook_done`); non-zero otherwise so `hushnote catchup` retries.
- Log: `~/.local/state/meeting-notes/mem0-hook.log`.

### Known blocker (2026-06-16)

mem0 on home-k3s is **down**: the pod is `Pending` because its local PersistentVolume has node
affinity to a node that's currently `unreachable` (the other nodes don't match the PV). Recall +
hook pushes will 503 until that node is recovered. The hook fails gracefully and queued meetings
re-push via `hushnote catchup` once mem0 is back.

## Krisp → mem0 bridge

Krisp captures Mac/VDI/mobile meetings but has **no API/MCP**, and mem0 is **LAN/Tailscale-only**
(public internet gets 403). So a cloud relay can't POST to mem0 directly — something on the network
must do the final hop. Two ways to wire it; both end at `meeting_mem0.push_memory()`.

**Option 1 — real-time webhook (recommended).**
```
Krisp → Zapier (trigger: new meeting note)
      → "Webhooks by Zapier" POST  https://<host>.<tailnet>.ts.net/krisp
        header  X-Webhook-Secret: <secret>
        JSON    {title, date, summary, source:"krisp"}
      → krisp-mem0-webhook.py (on the LAN box) → mem0
```
Run + expose (mem0 stays private; only this locked-down port is public):
```bash
MEM0_WEBHOOK_SECRET="$(openssl rand -hex 24)" ./krisp-mem0-webhook.py   # 127.0.0.1:8788
HOST=0.0.0.0 PORT=8788 MEM0_WEBHOOK_SECRET=... ./krisp-mem0-webhook.py   # to expose
tailscale funnel 8788                                                    # public HTTPS → port
```
For always-on, wrap it in a `systemd --user` unit (same pattern as the Parakeet daemon).

**Option 2 — no inbound exposure (poll a relay).** If you'd rather not expose anything: Krisp →
Zapier → drop the note into a sink you control (Notion DB row, Google Sheet, a Maildir email), then
a cron on the LAN box reads new entries and pipes each to `meeting-note-mem0 --source krisp …`.
More moving parts (polling + dedup), zero inbound.

Either way, Krisp meetings land in mem0 with `source=krisp`, `agent_id=meetings` — recall them the
same way as HushNote ones via the `mem0-ops` skill, alongside your Linux/in-person notes.

> ⚠️ Confirm it's acceptable to relay one company's Krisp seat through your homelab before wiring a
> work account. And there's no live 2xx test yet — mem0 is down until home-config PR #26 merges.

## Fellow.ai (alternative to Krisp, if MCP→Claude + auto-tickets matter)

1. **Confirm corporate IT/legal allow a third-party meeting bot first.**
2. Account + connect Google/MS Calendar; enable zero-retention on recordings + transcripts.
3. Admin enables *Workspace Settings → Security → "Allow users to create MCP Server connections"*,
   then add a custom connector in Claude named "Fellow" (`https://fellow.app/mcp`, OAuth) → sign in.
   For Claude Code try `claude mcp add --transport http fellow https://fellow.app/mcp` (Claude Code
   support inferred — verify the tools appear).
4. Wire action-item → GitHub / bidirectional Jira as desired.
