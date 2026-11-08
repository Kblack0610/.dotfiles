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
| A "Mic not found" popup, and no take starts | The mic named by `GUNGAN_SOURCE` is gone, usually a webcam that dropped off USB (`journalctl -k \| grep -i 'cannot enable'`) | Replug it on a port on the PC itself, then check with `gungan health`. The kernel gives up on a failing port, so only a replug brings it back. |
| Every take is "nothing heard" | gungan is recording a silent source | `wpctl status` lists the sources; set `GUNGAN_SOURCE` in `~/.config/gungan/config` to the mic, and check its volume (`wpctl set-volume <id> 0.7`; at 1.0 loud speech clips) |
| Some words are missing from a take | Usually a quiet mic, or (before gungan-speak #9) a pause of 1.2 s or more in a stream | Measure it: `gungan eval --record` once, then `gungan eval` lists every dropped word per mic. Both lanes lift quiet input by up to +30 dB; below that, raise the source volume or move closer. |
| Which mic should gungan use | It records the default source unless `GUNGAN_SOURCE` names one | Record every candidate at once (`gungan eval --record --source umc=<node> --source cam=<node>`) and keep the one `gungan eval` scores best. |
| A take with no speech types "I'm sorry. I'm sorry." (record lanes) | Hotword biasing invents it on room noise | `ASR_VAD_MODEL` in `parakeet-asr.service` skips a take with no speech; the model is `silero_vad.onnx` from the k2-fsa `asr-models` release in `~/.local/share/asr/models/`. `gungan health` lists `"vad": true`. |
| No red mic on the bar during a take | Waybar was started before `custom/gungan` existed | `systemctl --user restart waybar` |
| The bind does nothing | Hyprland has not reloaded the config | `hyprctl reload` |
