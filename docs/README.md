# Docs index

What lives in this repo's `docs/` tree. Cross-repo rules (CI, plans, skills, UI, layout) are not here: they live in `~/.local/src/docs/`, indexed by its `README.md`.

## Start here

- [overview.md](overview.md): what the two projects here (notes-cockpit and agent-runtime) do, their features and status.
- [architecture.md](architecture.md): the repo layout and how each project is built.

## Guides

- [desk.md](desk.md): `desk`, which switches the bar and the notifier.
- [laptop-keyboard.md](laptop-keyboard.md): `laptop-kbd`, which turns the laptop keyboard off and on.

## Operations

[operations/](operations/) holds the runbooks and the reference for each operated tool:

- [operations/boot-cause.md](operations/boot-cause.md): how each boot records how the one before it ended.
- [operations/claude-acct-tokens.md](operations/claude-acct-tokens.md): the long-lived token each Claude account holds.
- [operations/claude-acct-usage.md](operations/claude-acct-usage.md): adding a `claude-acct` usage source, such as a LiteLLM route plus a `litellm-key` row.
- [operations/deploy.md](operations/deploy.md): deploying the cockpit and agent-runtime.
- [operations/event-catalogue.md](operations/event-catalogue.md): the list of events each product sends.
- [operations/git-hooks.md](operations/git-hooks.md): the global git hook dispatcher.
- [operations/github-app.md](operations/github-app.md): the GitHub App behind the fleet's `gh` reads.
- [operations/local-llm.md](operations/local-llm.md): the local Qwen model on the workstation.
- [operations/mkt.md](operations/mkt.md): `mkt`, the outbound ledger.
- [operations/release-state.md](operations/release-state.md): what is pinned and live on each deploy channel.
- [operations/store-reviews.md](operations/store-reviews.md): store reviews, playtest feedback and Sentry issues.
- [operations/store-sales.md](operations/store-sales.md): yesterday's store and Steam sales.
