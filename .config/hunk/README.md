# hunk

Config for [hunk](https://hunk.dev), the terminal diff viewer lazygit opens on `X`. `stow --no-folding .` links each file into `~/.config/hunk/`, which stays a real directory because hunk writes `state.json` there.

## `#task` in a review note

Review notes live only in the hunk session. `extensions/task-tag.ts` files the ones you tag through the `notes` CLI when you save a new note:

- `#task:<project>` adds a row to that project's sheet: `notes ptask <project> add "<text> (<file>:<line>) #low"`.
- `#task` alone resolves the repo to its project boards (`project_lab_names` in `~/.config/shared-hooks/project-name.sh`). Exactly one board gets the row; none or several send it to `notes inbox` instead, so use `#task:<project>` in a repo with more than one board (dotfiles has `agent-runtime` and `notes-cockpit`).

The tag is stripped from the row text. A priority tag in the note (`#urgent`, `#high`, `#low`) replaces the default `#low` on a board row. Only newly saved notes count: editing an old note to add `#task` does nothing, and agent comments are never filed. A toast says where the row went, or why it was not filed.

Tests: `bun test ./tests/hunk/task-tag.test.ts` from the repo root.
