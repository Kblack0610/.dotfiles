# meeting-notes

Glue between a local meeting recorder and this machine's Claude + mem0 stack. Part of the
cross-environment meeting-notes setup (plan: `~/.claude/plans/fathom-is-a-fantastic-streamed-lantern.md`).

Two tracks:

- **Online / corporate meetings → Fellow.ai** (bot mode, server-side capture). Works on the
  Windows VDI, corporate Mac, and Linux with nothing installed per-device. See "Fellow" below.
- **Private / in-person meetings on Linux → HushNote → this bridge → mem0 + Claude.**

## What's in here

| File | Role |
|---|---|
| `hushnote-mem0-hook.sh` | HushNote `POST_SUMMARY_HOOK` target. Reads the summary + sibling `*_metadata.json`, POSTs the summary to mem0 (`infer:false`, `agent_id=meetings`, per-meeting `run_id`). Symlinked to `~/.local/bin/hushnote-mem0-hook`. |
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

## Fellow.ai (online/corporate)

1. **Confirm corporate IT/legal allow a third-party meeting bot first.**
2. Account + connect Google/MS Calendar; enable zero-retention on recordings + transcripts.
3. Add the Fellow MCP connector to Claude (Settings → Connectors → Fellow.ai, `https://fellow.app/mcp`,
   OAuth). For Claude Code try `claude mcp add --transport http fellow https://fellow.app/mcp`
   (Claude Code support inferred, not vendor-documented — verify the 5 read tools appear).
4. Wire action-item → GitHub / bidirectional Jira as desired.
