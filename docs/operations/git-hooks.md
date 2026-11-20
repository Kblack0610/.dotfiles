# Git hooks: the global dispatcher

One `core.hooksPath` for the whole machine, so a repo's committed hook runs in every clone and worktree with no setup step. The rule it serves is `~/.local/src/docs/ci.md` speed lever 3; the plan is `prepush-every-repo`.

## How it works

- `.gitconfig` (stowed to `~/.gitconfig`) sets `core.hooksPath = ~/.config/git/hooks`.
- `.config/git/hooks/` holds one stub per hook (pre-commit, pre-push, commit-msg, post-checkout, post-commit, post-merge), each calling `dispatch <hook>`. `dispatch` runs the first that applies:
  1. the repo's committed `.githooks/<hook>`, when the `origin` owner is listed in `owners` or `owners.private` (the GitHub orgs and users and the Forgejo user we own; the private overlay holds `owners.private`, because the public repo's token scan refuses the client and studio names);
  2. the repo's own `.git/hooks/<hook>` (git-lfs, husky);
  3. nothing.
- A repo with its own local `core.hooksPath` (dotfiles, dotfiles-private, platform) overrides the global one and the dispatcher never runs there.
- A new hook name goes in as one more stub; a new owner is one line in `owners` (public name) or the private repo's `owners.private`.
- Scripts that must skip hooks keep passing `-c core.hooksPath=/dev/null`, which beats the global value.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| A repo's `.githooks/pre-push` does not run | Its `origin` owner is not in `owners` or `owners.private`, it has no `origin`, the file is not executable, or the repo sets its own `core.hooksPath`. Check `git config --show-origin core.hooksPath`. |
| A clone of someone else's repo runs nothing from `.githooks/` | By design. Add the owner to the list only for a repo we own. |
| `git lfs install --local` exits 2, "Hook already exists: pre-push" | With a global `core.hooksPath` git-lfs writes into the dispatcher dir, where the stubs already are, and refuses to overwrite them. The repo's lfs hooks in `.git/hooks` keep running through the dispatcher's fallback. Use `git lfs install --skip-repo`; never `git lfs update --force`, which would write through the stow links into this repo. |
| A hook in `.git/hooks` other than the six does not run | Git runs only `$core.hooksPath/<name>`. Add a stub for that name. |
| A fresh machine or the mac-mini runs no hooks | The dispatcher arrives with the next pull and stow of dotfiles. Check `git config --global core.hooksPath` and `ls ~/.config/git/hooks`. |

## Tests

`tests/integ/git_hook_dispatch.bats`: our origin runs `.githooks/`, a third-party origin does not, a repo with only lfs-style hooks still gets its `pre-push`, a local `core.hooksPath` wins, stdin and exit status reach the hook.
