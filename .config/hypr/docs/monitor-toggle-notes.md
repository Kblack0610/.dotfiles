# Monitor on/off in Hyprland — findings (why there's no software toggle)

**Status:** Abandoned 2026-06-29 in favor of a **physical monitor switch/power button**.
This doc captures *why*, so the wheel isn't reinvented.

## Goal
A keybind to turn a secondary monitor (DP-4) off/on on demand, with the primary
(HDMI-A-2) always protected.

## The two primitives, and the tradeoff

| Method | How | Layout count changes | Windows reflow | Stays off reliably? |
|---|---|---|---|---|
| **DPMS off** | `hyprctl dispatch dpms off <name>` | no — stays in layout | no | **YES** |
| **disable** | `hyprctl keyword monitor <name>,disable` | yes — drops out | yes | **NO** (see below) |

- DPMS and "disabled" are **independent** states. A monitor can be `disabled=false`
  (in layout) yet `dpmsStatus=false` (panel powered off → black). Check **both** fields
  when reasoning about "is this screen actually showing content."
- Re-enabling a disabled output does **not** power its panel back up — you must also
  `hyprctl dispatch dpms on <name>`.
- `hyprctl keyword monitor <name>,...` can **disable** an output but cannot **wake** a
  disabled one; only `hyprctl reload` re-applies the catch-all and brings it back.

## The blocker that killed the `disable` approach

DP-4 is a **DisplayPort** monitor. When disabled it loses signal → enters standby →
**re-announces itself over DP** (Hyprland sees a hotplug "monitor added" event).
Our `conf.d/monitors.conf` has a catch-all:

```
monitor=,preferred,auto,1   # auto-enable ANY connected monitor
```

So the moment DP-4 re-handshakes, the catch-all **auto-re-enables it**. Result: disabling
DP-4 is **intermittent** — sometimes it sticks (no re-handshake during the window),
sometimes it pops back on ~4s later. Observed live, both outcomes, same command. That
unpredictable "I turned it off and it came right back on" is the dealbreaker.

`misc:disable_autoreload = 0` (autoreload is on), but that's not the trigger — the trigger
is the DP re-announce + catch-all.

## Options that *would* have worked (not implemented)

1. **DPMS + move windows** — move DP-4's workspaces to the primary, then `dpms off DP-4`.
   Reliable dark + windows on primary. Monitor count stays 2.
2. **DPMS only** — `dpms off`/`on`. Reliable, but windows stay assigned to the dark screen.
3. **disable + hotplug daemon** — a `socat` listener on `$XDG_RUNTIME_DIR/hypr/$HIS/.socket2.sock`
   that re-asserts `monitor=DP-4,disable` whenever DP-4 re-announces. Works but **fights the
   hardware** → visible flicker. Needs `socat` (not installed).
4. **Pin explicit per-output rules** — drop the `monitor=,preferred,auto,1` catch-all and
   list each output explicitly, so a re-announced DP-4 isn't auto-enabled. More brittle on
   a portable config that should "just work" on any connector.

## Decision

Removed the `Super+B` keybind and `scripts/monitor-toggle.sh`. A physical switch is simpler
and 100% reliable. If revisiting, start from option 1 above.

## If you just want a quick one-off from a terminal
```bash
hyprctl dispatch dpms off DP-4   # go dark (reliable)
hyprctl dispatch dpms on  DP-4   # wake
```

## History
- `bcb60ef` added monitor toggle
- `1aef052` hardened it (guards, single-monitor rescue, wake-panel-on-enable)
- removal commit — this doc + keybind/script removed
