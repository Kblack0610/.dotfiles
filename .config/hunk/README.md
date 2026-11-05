# hunk

Config for [hunk](https://hunk.dev), the terminal diff viewer lazygit opens on `X`. `stow --no-folding .` links each file into `~/.config/hunk/`, which stays a real directory because hunk writes `state.json` there.

## `#task` in a review note

Review notes live only in the hunk session. `extensions/task-tag.ts` files the ones you tag through the `notes` CLI when you save a new note:

- `#task:<project>` adds a row to that project's sheet: `notes ptask <project> add "<text> (<file>:<line>) #low"`.
- `#task` alone resolves the repo to its project boards (`project_lab_names` in `~/.config/shared-hooks/project-name.sh`). Exactly one board gets the row; none or several send it to `notes inbox` instead, so use `#task:<project>` in a repo with more than one board (dotfiles has `agent-runtime` and `notes-cockpit`).

The tag is stripped from the row text. A priority tag in the note (`#urgent`, `#high`, `#low`) replaces the default `#low` on a board row. Only newly saved notes count: editing an old note to add `#task` does nothing, and agent comments are never filed. A toast says where the row went, or why it was not filed.

Tests: `bun test ./tests/hunk/task-tag.test.ts` from the repo root.

## Sending notes to an agent

Point at lines while you browse, then send them all as one request. `agent-request` (`.local/bin/`) keeps one draft per repo at `~/.agent/requests/<project>/<repo>.md` and is its only writer. nvim and hunk both add to it, so notes from both go out together.

In nvim, on a file or a visual selection:

| Key | Does |
|---|---|
| `<leader>ia` | add a note on this line, or on the selected lines |
| `<leader>il` | list the notes in quickfix, to jump between them |
| `<leader>io` | open the draft to edit or reorder notes |
| `<leader>iq` | send as one `agent-queue` item (asks for a title) |
| `<leader>is` | send to the Claude session working in this repo |
| `<leader>ic` | clear the draft |

In hunk, `A` copies your notes from the review into the draft (agent and AI notes stay behind; pressing it again adds only new ones), then offers queue, session, or keep drafting. Remap it with `agent-request.send` in `[keybindings]`. `hunk open` loads no extensions and takes no notes, so use nvim for files with no diff.

Sending to the session archives the draft to `~/.agent/requests/<project>/sent/` and types one line into the pane: `My notes from a pass over this repo (N): @<file> - ...`. The session reads the file through the `@`. The pane is the one live Claude session whose cwd is in the repo. When none or several match, nvim and hunk ask which one. A session sitting in a dialog is refused until you answer it.

| Problem | Fix |
|---|---|
| "no live Claude session in <repo>" | Start one in that repo, or send with `<leader>iq` instead |
| "the line is in <pane>'s input box" | The paste landed but Enter was not taken: press Enter in that pane |
| "the session ... is in a dialog" | Answer the question or permission prompt there, then send again |
