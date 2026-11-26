# Local model (Qwen3.5-9B on the workstation)

One small model runs at home: Qwen3.5-9B (IQ4_XS GGUF) under llama.cpp's `llama-server`, on the workstation's RTX 4060 Ti. The AMD card keeps the desktop and Sunshine; RustDesk shares the 4060 Ti, so the model is sized to leave at least 1.5 GB of its 8 GB free. Measured 2026-11-13: 5.36 GB used in all while generating (RustDesk 0.3 GB of it), about 48 tokens a second.

Everything reaches it through the LiteLLM gateway route `local (qwen3.5-9b)`, never by host and port. That route is priced 0 and has no fallback: when the workstation is off or asleep, a call fails instead of moving to a paid model.

## Pieces

| Piece | Where | Owns |
|---|---|---|
| Server | `.config/systemd/user/llama-server.service` (this repo) | model file, context, GPU pin, flags; listens on `:8780` |
| Install | `install.sh --with llm` (`setup_local_llm` in `install_arch.sh`) | packages `llama-cpp` + `ggml-cuda`, the model download and checksum, the UFW rule, enabling the unit |
| Gateway route | home-config `apps/litellm/config.yaml`, README "Local model key" | the route, its no-fallback rule, the `ask-local` key |
| Client route | private overlay `.config/agentctl/routes/gateway-local.route` | gateway URL, model name, key file |
| Terminal client | `.local/bin/ask-local` (this repo) | one-shot, stdin, `--json`, `--schema`, `--chat`, `--free` |
| Free fallback route | private overlay `.config/agentctl/routes/gateway-free.route` | the gateway's `free-qwen (qwen3.8-27b)` on Groq, on the `fleet-nim` key; used only by `ask-local --free` |
| Claude Code | skill `local-model` (private overlay) | when an agent hands a job to `ask-local` |

## Use it

```
ask-local "explain what a GGUF file is in two sentences"
git diff --staged | ask-local "write a one-line commit message"
ask-local --json "three fruits as {\"fruits\": [..]}"
ask-local --schema person.json "extract the person: Ada Lovelace, born 1815"
ask-local --chat
```

From Claude Code, ask it to "use the local model" or run `/local-model <job>`. From opencode, run `ask-local` in its shell. Neither harness runs on the 9B itself: its 16K context is smaller than opencode's system prompt.

Good jobs: summaries, labels and triage, extracting fields to JSON, rewrites, commit-message drafts. Poor jobs: multi-step reasoning, math, facts it would have to recall, anything with tools.

## When the local model is down or busy: `--free`

```
git diff origin/main | ask-local --free "summarize this public diff in 5 bullets"
```

`--free` is the caller's statement that the input is public: no personal, work or client data. Only then does a call that got no answer from the local model (the workstation is off, a 429 or a 5xx) go once to route `gateway-free`, Groq's `free-qwen (qwen3.8-27b)`, declared as public data. A refused key (401, 403), an empty answer or a bad request stays a failure, since the free route would fail the same way. The route is not personal-safe, so `ask-local --route gateway-free` without `--free` is refused by the interlock.

Groq's free plan allows 30 requests a minute, 8K tokens a minute and 200K tokens a day per model (home-config `apps/litellm/config.yaml`, read 2026-11-19), and one gateway route is shared with the fleet's trials. The gateway route holds a lower request and token rate for every caller on the key, and is what refuses a shared overrun. `ask-local` keeps its own calls in `~/.local/state/ask-local/free-ledger` (one `epoch tokens` line per call, under `flock`) inside the minute and day limits named by `FREE_RPM`, `FREE_TPM` and `FREE_DAY_TOKENS` in the script, the day's share being half of Groq's, so fleet trials keep the rest. Each call counts as bytes/2 plus `--max-tokens`, an estimate that suits prose. A call over a limit is skipped and prints why; it is never waited out. A prompt of more than `(FREE_TPM - max-tokens) * 2` bytes never fits, so split it or leave `--free` off. `--free` falls back from the default local route only.

`--free` does not work with `--chat`. Callers surveyed 2026-11-25 for a public, small one-shot job: no script calls `ask-local`, only sessions through the `local-model` skill. The `agentctl-run` call agents (`comms`, `version-summary`, the inbox and judge agents) all declare `DATA_CLASS=personal` and sit on paid Claude or Lazer routes, so none moves to Groq.

## Check it

```
systemctl --user status llama-server
curl -s localhost:8780/health
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
ask-local "say ok"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ask-local: agentctl-run: unknown route 'gateway-local'` | the private overlay is not stowed on this machine | stow `~/.dotfiles-private`, or run on the workstation |
| `ask-local: the gateway refused the call, and the route sent no key (401)` | no `~/.local/state/ask-local/litellm.key` | mint it per home-config `apps/litellm/README.md` "Local model key", `chmod 600` |
| `failed (500)` with a connection error | llama-server is down or the workstation is off | `systemctl --user status llama-server`; `journalctl --user -u llama-server` |
| unit shows `condition failed` | the model file is missing | `install.sh --with llm` downloads and checks it |
| `install.sh --with llm` stops with `UFW is inactive` | the server checks no key, so it only starts behind a firewall | allow SSH, `sudo ufw enable`, re-run |
| `--free skipped, ...` | the free route's minute or day window in the ledger is used up, or the prompt is too big for 8K tokens a minute | wait for the window, or run without `--free`; the ledger is `~/.local/state/ask-local/free-ledger` |
| `unknown route 'gateway-free'` after `--free` | the private overlay is not stowed on this machine | stow `~/.dotfiles-private` |
| `refused the key (401)` or a 403 naming the model | the key lacks the route | `/key/update` the key's `models` to include `local (qwen3.5-9b)` |
