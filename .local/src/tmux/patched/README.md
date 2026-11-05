# tmux 3.8, patched

tmux 3.8 can segfault when a tree-mode window kills the window it was opened from: Prefix+w, then `x y` on that window, or `t X y` with it tagged. The in-pane prompt new in 3.8 keeps drawing on the freed pane, so the next key reads `wp->window` as NULL in `mode_tree_draw` and every session on that server dies. That is what took down hub on 2026-11-04. Upstream issue: https://github.com/tmux/tmux/issues/5728.

`tree-mode-self-kill.patch` is upstream commit 0985de0bc6 unchanged. The test image applies the same file (`tests/Dockerfile`) and `tests/ui/tree_self_kill.bats` pins the behaviour.

## Install

```bash
cd ~/.dotfiles/.local/src/tmux/patched
BUILDDIR=~/.cache/tmux-pkg PKGDEST=~/.cache/tmux-pkg SRCDEST=~/.cache/tmux-pkg makepkg -f
sudo pacman -U ~/.cache/tmux-pkg/tmux-3.8-1.2-x86_64.pkg.tar.zst
```

`install_arch.sh` runs the same steps. A running server keeps the binary it started with, so a server is only safe after its next restart: `tmux -L hub display -p '#{version}'` cannot show this, the version string is still 3.8, but `ls -l /proc/$(tmux -L hub display -p '#{pid}')/exe` says `(deleted)` until it restarts.

## Delete this directory when

A tagged tmux release contains 0985de0bc6 (the first after 2026-10-13, so 3.9). Then set `TMUX_REF` to it in `tests/Dockerfile`, `tests/docker.sh` and `.github/workflows/tests.yml`, drop `install_tmux_patched` from `install_arch.sh`, and keep `tests/ui/tree_self_kill.bats`.

A repo package newer than 3.8-1.2 that is still 3.8 replaces this one on `pacman -Syu` and may not carry the fix. Check `pacman -Q tmux` after an upgrade.
