# Local model (Qwen3.5-9B on the workstation)

One small model runs at home: Qwen3.5-9B (IQ4_XS GGUF) under llama.cpp's `llama-server`, on the workstation's RTX 4060 Ti. The AMD card keeps the desktop and Sunshine; RustDesk shares the 4060 Ti, so the model is sized to leave at least 1.5 GB of its 8 GB free.

Everything reaches it through the LiteLLM gateway route `local (qwen3.5-9b)`, never by host and port. That route is priced 0 and has no fallback: when the workstation is off or asleep, a call fails instead of moving to a paid model.

## Pieces

| Piece | Where | Owns |
|---|---|---|
| Server | `.config/systemd/user/llama-server.service` (this repo) | model file, context, GPU pin, flags; listens on `:8780` |
| Install | `install.sh --with llm` (`setup_local_llm` in `install_arch.sh`) | packages `llama-cpp` + `ggml-cuda`, the model download and checksum, the UFW rule, enabling the unit |
| Gateway route | home-config `apps/litellm/config.yaml`, README "Local model key" | the route, its no-fallback rule, the `ask-local` key |
| Client route | private overlay `.config/agentctl/routes/gateway-local.route` | gateway URL, model name, key file |
| Terminal client | `.local/bin/ask-local` (this repo) | one-shot, stdin, `--json`, `--schema`, `--chat` |
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
| `ask-local: route gateway-local did not resolve` | the private overlay is not stowed on this machine | stow `~/.dotfiles-private`, or run on the workstation |
| `ask-local: route gateway-local gave no key` | no `~/.local/state/ask-local/litellm.key` | mint it per home-config `apps/litellm/README.md` "Local model key", `chmod 600` |
| `failed (500)` with a connection error | llama-server is down or the workstation is off | `systemctl --user status llama-server`; `journalctl --user -u llama-server` |
| unit shows `condition failed` | the model file is missing | `install.sh --with llm` downloads and checks it |
| `refused the key (401)` or a 403 naming the model | the key lacks the route | `/key/update` the key's `models` to include `local (qwen3.5-9b)` |
