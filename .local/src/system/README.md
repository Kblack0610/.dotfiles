# storage

`storage` shows where the disk space went on every drive in the machine, including drives that are plugged in but not mounted. It has three faces:

- The waybar module next to memory shows root use% and turns red at 90%. Hover it for the full overview, click it to open the picker.
- `storage` opens the picker. The header shows the drives and what can be reclaimed; below it every bucket is listed by size, with a preview of its biggest folders.
- `storage overview` prints the same overview the tooltip shows.

## Keys in the picker

| Key | Does |
|---|---|
| enter | Browse that bucket with `dua` (stays on its drive). Delete from inside dua if you want to. |
| ctrl-x | Run the bucket's reclaim command. It shows the command and runs it only after you type `y`, then rescans that bucket. |
| ctrl-r | Rescan every bucket. Takes about 2 minutes on a full 2 TB disk. |
| ctrl-d | Full drive detail: `lsblk` plus `duf`. |
| esc | Quit. |

## What the overview shows

- Drives: every disk from `lsblk`, mounted or not. Unmounted ones say `not mounted (ext4)`, blank ones say `no filesystem`, and a read-only mount says so. EFI partitions and zram are left out. A drive that gets mounted later shows up on the next refresh, with nothing to configure.
- Network: NFS, SMB and sshfs mounts. Each one gets 2 seconds to answer (`STORAGE_NET_TIMEOUT`), so a hung NAS shows `not responding` instead of freezing the bar.
- Biggest: the largest buckets, plus an "everything else" row per drive. That row is the drive's used space minus its buckets, so nothing hides.
- Reclaimable: each bucket that has a reclaim command, with its size. For worktrees, only the trees `wt gc` would actually reap are counted.

Drive usage is read live on every call. Bucket sizes come from the last scan, and the overview says how old that is.

## Buckets

Buckets live in `~/.config/storage/buckets`, one per line:

```
label|path|reclaim command
Trash|~/.local/share/Trash|gio trash --empty
Steam|~/.local/share/Steam|
```

- Symlinks are followed, so a bucket that moved to another drive is filed under that drive.
- Leave the reclaim command empty for anything that is not safely rebuildable.
- Do not nest buckets (one inside another counts the inner one twice).
- A path that does not exist on this machine is skipped.

## Scanning

`storage-scan.timer` runs `storage scan` hourly and 5 minutes after boot, at idle I/O priority. Enable it once per machine:

```
systemctl --user enable --now storage-scan.timer
```

`storage scan Trash Steam` rescans just those buckets. The cache is `~/.cache/storage/` (`scan.tsv`, one `children/<label>.tsv` per bucket, `reapable.tsv`).

## Moving a bucket to another drive

On the desktop the second NVMe is mounted at `/data` (btrfs, `compress=zstd`, `nofail` in fstab by UUID). Steam, the Asset Store cache, Downloads and the phone-backup stage live there, each behind a symlink at its old path, so apps and the buckets file need no change:

| Old path | Lives at |
|---|---|
| `~/.local/share/Steam` | `/data/Steam` |
| `~/.local/share/unity3d/Asset Store-5.x` | `/data/unity/Asset Store-5.x` |
| `~/Downloads` | `/data/Downloads` |
| `~/.cache/phone-backup` | `/data/phone-backup` |

To move another bucket, close whatever writes to it, then `rsync -aHAX --remove-source-files <old>/ /data/<name>/`, check nothing is left (`find <old> ! -type d`), remove the empty dirs and `ln -s /data/<name> <old>`. `--remove-source-files` deletes each file only once its copy landed, so an interrupted run loses nothing. To undo, do the same in the other direction and remove the link first.

Worktrees and `~/dev` stay on the root drive: live sessions have them open, and Unity copies `Library/` with reflinks, which only work inside one filesystem.

## Install

Needs `jq`, `fzf`, and `dua-cli` (for browsing): `sudo pacman -S dua-cli`. All three are in `installation_scripts/packages.conf`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Tooltip says `No scan yet` | The timer has not run. `systemctl --user enable --now storage-scan.timer`, or run `storage scan`. |
| `sizes scanned 5h ago` | The timer stopped. `systemctl --user status storage-scan.timer`, and `journalctl --user -u storage-scan` for the last run. |
| Root's "everything else" reads `none (compressed fs)` | The root btrfs is mounted with `compress=zstd`. `du` counts files at their uncompressed size, so the buckets add up to more than the drive has used. Bucket sizes on that drive run a little high for the same reason. |
| enter says `dua is not installed` | `sudo pacman -S dua-cli`. |
| A network mount says `not responding` | The NAS did not answer `df` within 2 seconds. Check it with `findmnt -t nfs,nfs4,cifs` and `ls <mountpoint>`. |
| Bar module missing | It is a toggleable module: `~/.config/waybar/modules.sh on storage`. |
| A move to `/data` ends with rsync code 23, `failed to remove ... Permission denied` | A root-owned folder in the source (often from a `sudo unzip`). The copies are made; `sudo rm -r` the leftover folder, `sudo chown -R $USER: ` its copy on `/data`, then make the link. |
| `umount` leaves the drive still mounted | It was mounted twice on the same point (a mount command run twice). `findmnt -S <partition>` lists every mount; unmount until it is empty. |
