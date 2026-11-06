# didn't we set it up differently earlier today, in a different window?

2026-11-04 22:47 UTC

Yes, and this window is that new setup. Before #851, merged today at 13:02 PST, every pass ran in a tmux session of its own called `shepherd`. #851 moved the pass into window `shepherd` of hub session `dotfiles`, next to the chats. It reuses that window for each pass, and Prefix o opens it. This pass is running in hub dotfiles:shepherd, so the change is live. When the new window takes over, the old shepherd session is closed once the pass inside it is idle or gone. #856 (13:17) then put the pass, its verdict and whether it is stuck on every telemetry surface.
