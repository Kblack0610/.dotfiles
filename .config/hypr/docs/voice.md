# Voice into a Claude session

| Key | What it does |
| --- | --- |
| Super+R | gungan stream: words are typed into the focused window as you talk; press again to stop |
| Super+Shift+R | gungan record: press, talk, press; the whole take is typed into the focused window |
| Super+Alt+R | agent-voice: press, talk, press, then pick a Claude session (or a new one) to send it to |
| Super+Ctrl+R | force-kill a stuck take |

While a take runs, a red mic sits on the bar beside the workspaces (`custom/gungan`, `.config/waybar/config.base`). Clicking it stops a stream.

## Sending a take to a Claude session

Super+Alt+R sends speech to a Claude session that you are not looking at, or starts a new session with it.

1. Press Super+Alt+R and talk. The red mic on the bar shows the take.
2. Press Super+Alt+R again. gungan transcribes the take, then a floating picker opens with the text at the top.
3. Pick a target and press Enter:
   - The first row, marked `paged`, is the session your newest page points at (its `tmux:` ref).
   - Next come the other live sessions, idle ones first, then busy ones. A session in a dialog is left out.
   - Last come the `new session in <project>` rows. Each one queues the text as an agent-queue item and starts it with `fleet-dispatch start --item`.
4. A popup says what happened. Esc sends nothing, and the text stays on the clipboard.

gungan records the source named by `GUNGAN_SOURCE` in `~/.config/gungan/config`, not the system default, because audio work moves the default to an instrument input.

Scripts send through the same path: `agent-voice send --to tmux:hub/dotfiles:3 "text"`, `--to pane:hub/%77`, or `--to new:dotfiles`. Typing goes through `agent-panel send` behind the one-pane guard in `.local/lib/agent-pane.sh`, which `agent-request send --session` uses too.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The second press opens no picker | gungan heard nothing, or it failed | A failure shows a "gungan failed" popup; the full error is in `$XDG_RUNTIME_DIR/agent-voice/gungan.log`. With no popup, nothing was heard, so speak closer and retry. |
| "unknown flag --print" in gungan.log | The main checkout's gungan submodule is older than gungan-speak #5 | `git -C ~/.dotfiles submodule update .local/src/gungan` |
| "Voice: not sent ... in a dialog" | The session showed a prompt between the pick and the send | Answer the dialog, then paste the text from the clipboard |
| "Voice: not submitted" | The pane did not take the Enter | Press Enter in that pane; the text is in its input box |
| Every take is "nothing heard" | gungan is recording a silent source | `wpctl status` lists the sources; set `GUNGAN_SOURCE` in `~/.config/gungan/config` to the mic, and check its volume (`wpctl set-volume <id> 0.7`; at 1.0 loud speech clips) |
| No red mic on the bar during a take | Waybar was started before `custom/gungan` existed | `systemctl --user restart waybar` |
| The bind does nothing | Hyprland has not reloaded the config | `hyprctl reload` |
