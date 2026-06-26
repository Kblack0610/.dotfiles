---
name: cred-status
description: Check how long enterprise session credentials have left before they expire, and gate agent work on it. Use when the user (or an agent) asks "how long do I have on my creds", "are my creds still valid", "when do my AWS creds expire", "check cred status", "is my session about to die", "watch my creds", or before/after running any cloud op that needs valid credentials (AWS CLI, eks/kubectl, terraform, devops-mcp). Concrete impl today = the Deloitte VDI+WSL AWS bridge (dev/qae/uat via `aws-azure-login`), where sessions are capped at ~1h and refresh is a MANUAL Windows-PowerShell login Claude cannot perform — so the core protocol is: check first, and if expired/low STOP and ask the user to re-auth rather than failing mid-op. Extensible to other providers.
---

# cred-status

Answer "how much runway is left on my credentials?" and let agents gate on it. Backed by the
`aws-cred-timer` script (on `PATH` at `~/.local/bin/aws-cred-timer`).

The point for **agent work**: short-lived enterprise sessions die mid-task. Instead of an AWS op
failing with `ExpiredToken` halfway through, check the runway *first*. If it's expired or too low,
**stop and ask the user to re-auth** — on the VDI bridge the refresh is an interactive Windows
passkey login that Claude/agents **cannot** run.

## Quick reference

| Goal | Command | Output |
|---|---|---|
| **Agent gate** (machine line + exit code) | `aws-cred-timer dev --check 10` | one line; exit `0`=OK, `1`=LOW, `2`=EXPIRED/NO_CREDS |
| One-shot human status | `aws-cred-timer dev -1` | single rendered panel, no loop |
| Live countdown in a window | `aws-cred-timer` (or `aws-cred-timer dev`) | color-coded loop, refresh 1s, bell at ≤5m & expiry |
| Other profile | `aws-cred-timer qae --check` / `aws-cred-timer uat` | same, for that profile |
| Slower refresh | `AWS_CRED_TIMER_INTERVAL=5 aws-cred-timer` | loop at 5s |

`--check` accepts the threshold in minutes as `--check 10` or `--check=10` (default 10).

## Agent protocol (gate before cloud work)

Before any op needing valid AWS creds (aws CLI, `aws eks get-token`/kubectl to the EKS cluster,
terraform, the `devops-mcp` cluster/db tools), run the gate and branch on the exit code:

```
if aws-cred-timer dev --check 10; then
  : # OK — enough runway, proceed
else
  : # LOW or EXPIRED — do NOT start; surface the refresh line to the USER and wait
fi
```

- **exit 0 (OK)** — ≥ threshold minutes left. Proceed.
- **exit 1 (LOW)** — valid but under threshold. For a long op, ask the user to re-auth first so it
  doesn't die mid-run. For a quick read, proceeding is usually fine.
- **exit 2 (EXPIRED / NO_CREDS / unparseable)** — STOP. Do not attempt the AWS call. Give the user
  the refresh command and wait for them to confirm it's done.

The `--check` line includes a `refresh="..."` field with the exact command for the profile —
relay that verbatim. Claude **cannot** run it (interactive passkey on the Windows side).

## How it works (this environment)

- **Source of truth:** the `aws_expiration` (ISO-8601) key that `aws-azure-login` writes into the
  shared credentials file per profile. Exact, not a guess.
- **Where:** the bridge points `$AWS_SHARED_CREDENTIALS_FILE` at the Windows file
  `/mnt/c/Users/keblack/.aws/credentials` (set in `~/.zshrc`). The script honors that env var and
  falls back to `~/.aws/credentials`. That Windows file is **CRLF** — the parser strips `\r`.
- **Window:** dev/qae/uat sessions are capped at ~**1 hour** (role `MaxSessionDuration` default).
  Expect hourly re-auth during long sessions.
- **Refresh (user-only, on Windows PowerShell):**

```
aws-azure-login --profile dev --mode gui
```

- **Profiles:** the bridged file usually holds only `[dev]`; `qae`/`uat` only appear after the user
  logs into them. `sbx` is a separate always-valid IAM user in `~/.aws/credentials` (no expiry — the
  gate reports `NO_CREDS no_aws_expiration` for it, which is expected; sbx never needs refresh).
- **kubectl/EKS** tokens are derived from the AWS session, so they die with it — gate on the AWS
  profile, not the token.

## Watch it in a window

For a long working session, run the live countdown in a side pane:

```
aws-cred-timer            # dev, refresh 1s; OK → WARNING(≤15m) → CRITICAL(≤5m) → EXPIRED, audible bell
```

## Adding a provider

The script is AWS-specific today. To extend cred-status to another short-lived credential
(e.g. a VPN session, a vaulted token), add a sibling checker that emits the same contract —
`<name> OK|LOW|EXPIRED|NO_CREDS left=… expires=… refresh="…"` plus exit `0`/`1`/`2` — and document
it here. Keep the exit-code contract identical so the agent gate above stays uniform.

## See also

- Memory: `reference_aws_dev_creds_expiry` (1h cap, refresh is user-only), `reference_aws_dev_access_vdi`
  (the VDI+WSL bridge), `reference_aws_auth_matrix_cross_repo` (csa vs policypal auth).
- `k8s-ops` skill (EKS token mint via `aws eks get-token`) and the `devops-mcp` server (cluster +
  db tools) both need a live AWS session — gate them with `--check` first.
