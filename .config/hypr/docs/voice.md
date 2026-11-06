# Voice into a Claude session

Super+Ctrl+R sends speech to a Claude session that you are not looking at, or starts a new session with it. To type speech into the window you are in, use Super+R (gungan record) or Super+Alt+R (gungan stream).

1. Press Super+Ctrl+R and talk. The waybar mic shows the take.
2. Press Super+Ctrl+R again. gungan transcribes the take, then a floating picker opens with the text at the top.
3. Pick a target and press Enter:
   - The first row, marked `paged`, is the session your newest page points at (its `tmux:` ref).
   - Next come the other live sessions, idle ones first, then busy ones. A session in a dialog is left out.
   - Last come the `new session in <project>` rows. Each one queues the text as an agent-queue item and starts it with `fleet-dispatch start --item`.
4. A popup says what happened. Esc sends nothing, and the text stays on the clipboard.

Super+Shift+R still kills a stuck take.

Scripts send through the same path: `agent-voice send --to tmux:hub/dotfiles:3 "text"`, `--to pane:hub/%77`, or `--to new:dotfiles`. Typing goes through `agent-panel send` behind the one-pane guard in `.local/lib/agent-pane.sh`, which `agent-request send --session` uses too.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The second press opens no picker | gungan heard nothing, or it failed | A failure shows a "gungan failed" popup; the full error is in `$XDG_RUNTIME_DIR/agent-voice/gungan.log`. With no popup, nothing was heard, so speak closer and retry. |
| "unknown flag --print" in gungan.log | The main checkout's gungan submodule is older than gungan-speak #5 | `git -C ~/.dotfiles submodule update .local/src/gungan` |
| "Voice: not sent ... in a dialog" | The session showed a prompt between the pick and the send | Answer the dialog, then paste the text from the clipboard |
| "Voice: not submitted" | The pane did not take the Enter | Press Enter in that pane; the text is in its input box |
| The bind does nothing | Hyprland has not reloaded the config | `hyprctl reload` |
