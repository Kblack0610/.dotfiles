# Claude account tokens (claude-acct setup-token)

Each Claude account in `~/.config/claude-acct/accounts` can hold one long-lived token (about a year) from `claude setup-token`. A session on that account gets it as `CLAUDE_CODE_OAUTH_TOKEN`, so a wiped or expired `.credentials.json` no longer stops it. The decision is ask czbM4Z (2026-11-17): tokens in rbw, no passwords stored, no browser driven by an agent.

## Set up (once per account, then once a year)

1. `rbw unlock`, and make sure `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are not set in that shell.
2. `claude-acct setup-token` walks every account in the file; `claude-acct setup-token alt` does one. For each it prints the email to sign in as.
3. `claude setup-token` runs on a scratch config dir (your logins are not touched), opens the browser, and prints the token. The script reads it off the screen; if it cannot, it asks you to paste it (hidden).
4. It then runs one `haiku` call on the token (billed to the subscription), probes the usage endpoint with it, and stores it in rbw as `claude-oauth-<account>`: the token is the password, the notes carry `email`, `minted`, `expires` and `usage_endpoint`.
5. An account that already has a token is skipped; `--renew` replaces it. A token that does not answer the verify call is refused and nothing is stored. The tool cannot tell which email the browser was signed in as, so read the email it prints before you approve.

## How a session gets its token

- `claude-acct run` / `cl` / the picker: exports the chosen account's token and unsets any inherited one (a parent session's token belongs to another account).
- `fleet-dispatch start` and `claude-acct move/unpark`: the launch line carries `CLAUDE_CODE_OAUTH_TOKEN="$(claude-acct token <dir>)"`, which the pane's shell runs at launch. The token is never typed into a pane, an argument list or a file. The launch env (`claude_launch_env`) drops any inherited token first.
- `agentctl-run` (timer runners): `route_account` sets the chosen account's token after the scrub.
- An account with no entry, or a locked rbw (one stderr line; every start prints it while rbw is locked), starts on its `/login` credentials exactly as before. rbw stays unlocked 24h after `rbw unlock` (`lock_timeout`), so an unattended start needs a recent unlock.
- A cloud session (`claude-cloud-run`) gets no token: it needs the full login.

## Usage reads

`claude-acct status`, `room` and `check usage` read the usage endpoint with the `/login` credentials, as before. A setup token carries only the inference scope, so the endpoint is expected to refuse it; `setup-token` probes it once and records the answer in the entry's `usage_endpoint:` note (`rbw get --raw claude-oauth-<account>`). The token is tried for the usage read only when the account has no usable login. Until someone runs `setup-token` the answer is unverified. If the endpoint refuses it, a wiped `.credentials.json` keeps sessions running but that account reads as unread in `status`; fix it with `/login` on that account.

## Expiry

`claude-acct check tokens` prints one line and exits 1 when a token is expired or within `TOKEN_WARN_DAYS` (`.config/claude-acct/pace.conf`, 30), 2 when rbw cannot be read. An account with no token is named and trips nothing. The auth alert (ar-2767) watches this line. Renew with `claude-acct setup-token --renew <account>`.

## Other machines

Claude may run on any of the human's machines (the 2026-11-12 "no Claude on any worker machine" ruling was lifted 2026-11-17). A machine with rbw unlocked reads the tokens from rbw. A fleet worker has none (headless, and nobody unlocks it after a reboot), so it reads a 0600 copy in `~/.config/claude-acct/tokens/<account>`, written by `claude-acct token push <host...>` from a machine whose rbw is unlocked. The push sends each token over ssh stdin and asks the host's own `claude-acct` to read it back, so a host whose dotfiles predate the copy fails by name. Re-run it after `setup-token --renew`. Revoke a leaked copy on claude.ai and renew.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `setup-token: rbw is locked` | `rbw unlock`, re-run. |
| `ANTHROPIC_API_KEY ... would not bill the subscription` | Unset both variables in that shell and re-run; the verify call must spend the plan. |
| `token not read from the screen; paste it` | The screen capture found no `sk-ant-oat` text. Paste the token claude printed. |
| `the token did not run a call; nothing stored` | The token was cut off or the account has no plan. Re-run, signed in to an account with a plan. |
| `rbw is locked, so <acct> starts on its login credentials` | The unattended start found rbw locked. `rbw unlock`; running sessions are not affected. |
| Session still stops with a login error | The account has no entry (`claude-acct check tokens` names it) or the token expired; run `setup-token --renew`. |
| `check tokens` exits 2 | rbw is missing or locked on this machine. |
| `token push: <host>: <acct> failed` | ssh to the host failed, or its dotfiles are too old to read the copy: pull them there, re-run. |
| `setup-token` paste box drawn thousands of columns wide | Fixed: it ran claude in a 4000-column pty. Pull the dotfiles. |
| Account reads unread after `.credentials.json` was wiped | Expected when the usage endpoint refuses setup tokens; `/login` on that account restores the read. |
