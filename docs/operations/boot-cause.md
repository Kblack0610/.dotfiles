# boot-cause

Every boot records how the boot before it ended, so a reboot is never "no logs, maybe RAM". A power cut leaves nothing on the dead host, so the cause is built from what survives.

## Read it

- `boot-cause last` prints the newest record: the cause, the evidence, what could not be checked, and the last 15 log lines. `--json` gives the raw line.
- The record is `~/.agent/boots/<host>.jsonl`, one line per boot, so a history is `jq -r '[.boot_epoch, .cause] | @tsv'` over it. The store-sync bulk pass carries it off the host.

## Causes, first match wins

| cause | what proves it |
| --- | --- |
| `clean-shutdown`, `clean-reboot` | the last 20 log lines hold the power-off, halt or reboot target |
| `kernel-panic` | systemd-pstore saved a dump after the log stopped |
| `ups-on-battery` | the last sample (taken within 5 minutes of the log ending) read a UPS status of OB, LB, ONBATT or LOWBATT |
| `battery-exhausted` | that sample was off AC at 5% or less |
| `out-of-memory`, `thermal-shutdown`, `gpu-fault`, `kernel-fault` | a matching line in the last 40 kernel lines, ranked below the power evidence |
| `house-power-event` | 3 or more other hosts' `node_boot_time_seconds` fall within 10 minutes of this boot |
| `thermal-suspect` | the last sample read the CPU at or over `FLEET_HOT_TCTL` (95 C), the throttle point fleet-assess holds at |
| `silent-death` | none of the above: a freeze, a hard reset or a power cut that took only this host |
| `previous-boot-not-in-journal` | the journal has no previous boot; the record says the journal is not persistent |

`silent-death` is the floor, not an unknown: it carries the journal's last line and `gaps`, the checks that could not run (no power sample, no UPS reachable, Prometheus unreachable). A `gaps` entry is a fix to make, not a verdict.

## How it runs

- `boot-cause-sample.timer` runs `boot-cause sample` every minute: AC, battery, UPS (NUT `upsc` or apcupsd `apcaccess`, when installed), load, CPU temperature (`cpu_temp_c`, from `.local/lib/cpu-temp.sh`: k10temp Tctl, else the hottest thermal zone, else null) and the running kernel, the last 10 kept in `~/.local/state/boot-cause/samples.log`. No event says a power cut is coming, so the last sample before the log stops is the only record of the state it died in.
- `boot-cause-record.service` runs `boot-cause record` once per boot, after `nm-online` (up to 60 s) so the Prometheus check can answer. A second run in the same boot adds nothing.
- The kernel-side capture it reads comes from `setup_journal` in `install_arch.sh`: a 2 GB journal and `systemd-pstore`.
- `git-store-fsck.service` runs `git-store-fsck boot` after the record. When the previous boot did not shut down cleanly (or this boot has no record), it checks `~/.agent`, `~/.notes` and every checkout in project-map.json `paths` for a zero-byte object or pack file and with `git fsck --connectivity-only` (commit-graph and reflogs left out, since both list commits gc pruned). An unclean shutdown on 2026-11-20 left a zero-byte object in `~/.notes` that stopped every notes sync for a day. A damaged store leaves the unit failed, and the `systemd-user-failed` watch pages it; the damaged repos are kept in `~/.local/state/git-store-fsck/damaged`, so a clean reboot before the repair re-checks them and fails again. `git-store-fsck` with no argument runs the same check by hand.

## Troubleshooting

| symptom | cause and fix |
| --- | --- |
| `gap: no UPS reachable` | no NUT or apcupsd on the host. Install and configure one (`upsc -l` must list a UPS); the sample picks it up with no change here. |
| `gap: no power sample` | the timer was not running at death. `systemctl --user enable --now boot-cause-sample.timer`. |
| `gap: Prometheus did not answer` | the host was offline at boot, or CC_PROM_URL is unset in `~/.config/command-center/env`. Query `node_boot_time_seconds` by hand for the window. |
| `previous-boot-not-in-journal` | `/var/log/journal` is missing or rotated. Run `setup_journal` from `install_arch.sh`. |
| `git-store-fsck.service` failed (the `systemd-user-failed` page) | `journalctl --user -u git-store-fsck` names each damaged repo. Refetch a zero-byte or missing object from origin (move the empty file aside, `git fetch origin`; never rewrite history), then `systemctl --user start git-store-fsck` re-checks and clears the unit. |
| `silent-death` again and again, with `cpu_temp_c` normal | read the `kernel ...: N of M recorded boots on it ended unclean` evidence line: a run of deaths that starts at one kernel or driver upgrade points at that upgrade (`grep upgraded /var/log/pacman.log`). Boot the previous kernel from `/var/cache/pacman/pkg` or the LTS entry to test it. |
| a sample's `cpu_temp_c` is null | the host has neither a k10temp hwmon nor a thermal zone. Add its sensor to `read_tctl` in `.local/lib/cpu-temp.sh`, the one reader. |
| `silent-death` on a house power cut | the other hosts' Prometheus targets were down too (so no co-reboot count). Read `hosts_rebooted_with` and the Prometheus boot times. |
