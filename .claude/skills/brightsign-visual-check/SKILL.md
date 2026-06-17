---
name: brightsign-visual-check
description: Visually verify the physical BrightSign player in the office through the webcam — snap the screen, classify its provisioning state (recovery / boot / BSN setup / content / black / error), OCR the identity block (serial, IP, firmware), and cross-reference the control plane. Use when the user asks "what's on the brightsign", "is the player up", "verify the provision visually", "watch the player while I insert the card", or during any new-player / runtime-update / resilience-scenario runbook step in the brightsign-fleet-platform repo. Builds on webcam-ops.
---

# brightsign-visual-check

Eyes on the physical BrightSign player (XT1144 on the office wall) via webcam.
Repo: `~/dev/gigantic-playground/fleet/brightsign-fleet-platform`.

## Capture

```bash
./scripts/webcam-check.sh <label>     # prints the saved image path
```

- Run with sandbox disabled (camera/TCC — see `webcam-ops` skill for the full
  gotcha list).
- Camera mapping: **W1 faces the player** (script default); the C920 faces the
  workbench wall; MacBook camera faces the user. Override: `WEBCAM_DEVICE=...`.
- Output lands in gitignored `.dev/webcam/<label>-<timestamp>.png`. Then
  `Read` the printed path.

## Screen-state taxonomy

| State | Visual signature |
|-------|------------------|
| `recovery` | "Please insert storage device for recovery" + BrightSign logo + identity block. Means no bootable SD card — the starting state for provisioning. |
| `boot-splash` | BrightSign / purple boot screen, no recovery text |
| `bsn-setup` | BSN.Cloud setup / registration / activation screens |
| `content` | Fleet card content rendering (retailer fixture UI) |
| `black` | No signal / blank — check player power + HDMI before blaming software |
| `error` | Anything else abnormal — describe verbatim |

The **identity block** (bottom of recovery/boot screens) is OCR-able:
model, IP, MAC, serial, firmware. Office player: XT1144, serial
`D7E80L001067`, MAC `90:ac:3f:18:47:31`, typically `192.168.1.x`.

## Cross-reference the control plane

With the serial read off the screen:

```bash
source ~/.config/fleet/admin.env   # $FLEET_ADMIN_KEY
curl -s -H "X-Admin-Key: $FLEET_ADMIN_KEY" \
  https://fleet.staging.amz.gigaplayops.com/api/v0/devices/<serial>   # or fleet.amz for prod
```

Compare what the screen shows vs what the control plane thinks
(`provision_status`, content assignment, `bsn_network`). Screen=content but
control-plane=absent (or vice versa) is a finding, not a success.

## Watch loop (provisioning verification)

For "watch the player while X happens", either loop inline
(sleep → capture → Read → classify, timestamped labels) or run the repo's
named workflow:

```
Workflow({ name: "provision-watch", args: { target: "content", maxRounds: 10, intervalSec: 30 } })
```

Expected progression on a fresh card insert:
`recovery → boot-splash → (bsn-setup on first boot) → content`.
A state that repeats > ~3 rounds or regresses is a stall — stop and diagnose
(player logs, control-plane record, `docs/boot-chain.md`).

## Runbook hooks

Use a capture as the verification step in:
- `docs/runbooks/new-player.md` — after card insert and after registration
- `docs/runbooks/update-player-runtime.md` — confirm the player came back
- `docs/runbooks/resilience-scenarios.md` — "did the screen actually recover"
  for atomic swap / recovery URL / cold-boot fallback tests
