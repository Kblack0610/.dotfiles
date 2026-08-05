#!/usr/bin/env bats
# md-render.sh — the ONE markdown renderer every preview pane goes through.
#
# Why this is worth testing rather than eyeballing: a renderer fails QUIETLY. A word cut at a
# column boundary, a marker leaking through, a paragraph short by exactly the width of an
# escape sequence — none of it errors, none of it shows in a diff, and all of it surfaces
# months later as "the pane looks a bit off". Every assertion here is one of those.
#
# Layout is always asserted on the text with the escapes STRIPPED, because the whole class of
# width bug is a string that looks the right length only while its invisible bytes are counted.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$MD_RENDER_LIB"
  export MD_WIDTH=50
}

plain() { sed -E 's,\x1b\[[0-9;]*[a-zA-Z],,g'; }

# `run` invokes a shell FUNCTION in this shell, so these keep md_render in scope. A
# `run bash -c '... md_render ...'` would silently render nothing: the subshell has no
# such function, and the pipeline would exit 0 with empty output.
mdr() { printf '%s\n' "$*" | md_render - | plain; }
mdr_raw() { printf '%s\n' "$*" | md_render -; }
mdr_over() { local max="$1"; shift; printf '%s\n' "$*" | md_render - | plain | awk -v m="$max" 'length($0) > m { print length($0) ": " $0 }'; }
mdr_lines() { printf '%s\n' "$*" | md_render - | plain | grep -c .; }

# ── the note's machinery must not reach the pane ─────────────────────────────

@test "YAML frontmatter is stripped" {
  run mdr '---
id: summary
aliases: []
---

# Title

body text'
  assert_success
  refute_output --partial 'id: summary'
  refute_output --partial 'aliases'
  assert_output --partial 'TITLE'
  assert_output --partial 'body text'
}

@test "a --- that is not frontmatter stays a horizontal rule" {
  # The open must be line 1, or every mid-document rule swallows the rest of the note.
  run mdr 'before

---

after'
  assert_success
  assert_output --partial 'before'
  assert_output --partial 'after'
}

@test "every marker the tools address each other with is stripped" {
  run mdr '<!-- canonical: myapp -->
<!-- nextup:auto -->
## Now
state of things
<!-- /nextup:auto -->
<!-- STATUS:START -->
dated prose
<!-- STATUS:END -->'
  assert_success
  refute_output --partial '<!--'
  refute_output --partial 'nextup'
  refute_output --partial 'canonical'
  assert_output --partial 'state of things'
  assert_output --partial 'dated prose'
}

@test "a marker containing > is still stripped whole" {
  # The cockpit marker carries `branch=develop`, and /<!--[^>]*-->/ stops at the first `>`,
  # leaking the tail of the marker onto the pane. Hence the index()-based scan.
  run mdr '<!-- cockpit: vikunja=3 pathfilter=apps/x branch=develop -->
real text'
  assert_success
  refute_output --partial 'vikunja=3'
  refute_output --partial '\-\->'
  assert_output --partial 'real text'
}

@test "a comment spanning several lines is stripped whole" {
  run mdr '<!-- open
still inside
closed -->
visible'
  assert_success
  refute_output --partial 'still inside'
  assert_output --partial 'visible'
}

@test "stripped markers do not leave their blank lines behind" {
  # Three markers in a row would otherwise open the pane with three empty lines, and the note
  # would look like it starts halfway down.
  run mdr '<!-- a -->
<!-- b -->
<!-- c -->
text'
  assert_success
  assert_output '  text'
}

# ── wrapping: the reason the cut words and the arrows existed ────────────────

@test "no rendered line is wider than the requested width" {
  run mdr_over 48 "$(printf 'alpha bravo charlie delta echo foxtrot golf hotel india juliet %.0s' 1 2 3)"
  assert_success
  assert_output ''
}

@test "wrapping never splits a word" {
  # THE NEGATIVE CONTROL, and the one assertion here that cannot pass by accident: the
  # rendered text is re-joined and compared to the source word for word. A character wrap
  # (what fzf did) fails it on the first line.
  local para joined
  para='The recovery runbook remains stale and requires a full rewrite before the next release, and until that lands the restore drill cannot be repeated with any confidence at all.'
  joined="$(mdr "$para" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^ +| +$//g')"
  assert_equal "$joined" "$para"
  # ...and it must actually have wrapped several times, or the comparison proved nothing:
  # a single unwrapped line trivially re-joins to itself.
  run mdr_lines "$para"
  assert_success
  [ "$output" -ge 3 ] || fail "the fixture wrapped to $output lines - too short to be a control"
}

@test "a token wider than the pane is broken rather than left to be truncated" {
  # Found by rendering every real note rather than a fixture: a changelog carried a
  # 67-character env-flag identifier with nowhere to wrap. The preview window no longer
  # wraps, so an overlong line loses its tail SILENTLY -- a mid-token break is the honest
  # cut, and no character is lost.
  local tok
  tok='SOME_PUBLIC_FEATURE_FLAG_ENABLED/extra.someFeatureFlagEnabledLongEnough'
  run mdr_over 48 "- $tok"
  assert_success
  assert_output ''
  # every character survives the break
  local joined
  joined="$(mdr "- $tok" | sed -E 's/^ +- ?//; s/^ +//' | tr -d '\n')"
  assert_equal "$joined" "$tok"
}

@test "no continuation glyph is ever emitted" {
  # fzf's wrap-sign stamped a marker at the head of every continuation line. Rendering ahead
  # of fzf is what removes it, so nothing in here may reintroduce one.
  run mdr_raw "$(printf 'wrapping this paragraph across several rendered lines %.0s' 1 2 3 4)"
  assert_success
  refute_output --partial $'↳'
}

@test "a wrapped checklist item hangs under its own text" {
  # Otherwise the continuation lands at column 0 and reads as a separate, unchecked item.
  run mdr '- [ ] rewrite the database recovery runbook with corrected procedures and test it'
  assert_success
  assert_line --index 0 --regexp '^  \[ \] rewrite'
  assert_line --index 1 --regexp '^      [a-z]'
}

@test "a wrapped bullet hangs under its own text" {
  run mdr '- fix the facility placeholder that was racing a real 404 against its own assertion'
  assert_success
  assert_line --index 0 --regexp '^  - fix'
  assert_line --index 1 --regexp '^    [a-z]'
}

@test "a done item is still legible as done" {
  run mdr '- [x] shipped already'
  assert_success
  assert_output '  [x] shipped already'
}

# ── markdown as prose, not as source ────────────────────────────────────────

@test "headings lose their hashes" {
  run mdr '# Title

## Now

### Added'
  assert_success
  refute_output --partial '#'
  assert_output --partial 'TITLE'
  assert_output --partial 'NOW'
  assert_output --partial 'Added'
}

@test "a heading whose arrow was folded to ASCII does not keep it" {
  # `## -> For the agents` after the Unicode fold: the arrow is decoration, not the title.
  run mdr '## -> For the agents'
  assert_success
  assert_output 'FOR THE AGENTS'
}

@test "a link collapses to its text" {
  run mdr 'board [vikunja](https://vikunja.example/projects/3) and on'
  assert_success
  assert_output --partial 'board vikunja and on'
  refute_output --partial 'https'
}

@test "emphasis markers do not survive" {
  run mdr '**In progress** (Vikunja):
_a dated aside_'
  assert_success
  refute_output --partial '**'
  assert_output --partial 'In progress (Vikunja):'
  assert_output --partial 'a dated aside'
}

@test "snake_case identifiers are left alone" {
  # The reason `_` is stripped only at the START of a line: a global strip mangles every
  # identifier in a changelog, and a changelog is most of what this renders.
  run mdr 'New billing_notes table and a NULL user_type column'
  assert_success
  assert_output --partial 'billing_notes'
  assert_output --partial 'user_type'
}

@test "a fenced code block is passed through verbatim" {
  run mdr 'text
```
  keep   this    spacing
```'
  assert_success
  assert_output --partial 'keep   this    spacing'
  refute_output --partial '```'
}

@test "a table keeps its columns instead of being wrapped into prose" {
  run mdr '| a | b |
|---|---|
| 1 | 2 |'
  assert_success
  assert_output --partial '| a | b |'
}

# ── plain ASCII, and colour ─────────────────────────────────────────────────

@test "Unicode punctuation is folded, never dropped" {
  # iconv on its own DELETES an em dash and joins the two words it separated, which is why
  # the named substitutions run first and iconv is only the backstop.
  run mdr 'left—right and a → arrow'
  assert_success
  assert_output --partial 'left - right'
  assert_output --partial '-> arrow'
}

@test "no non-ASCII byte reaches the pane" {
  local out
  out="$(mdr 'curly ‘quotes’ an ellipsis… a bullet • and a middot ·')"
  run bash -c "printf '%s' \"\$1\" | LC_ALL=C grep -c '[^[:print:][:space:]]' || true" _ "$out"
  assert_output '0'
}

@test "PANEL_NO_COLOR renders the same text with no escapes at all" {
  local src coloured bare
  src='## Now
- [ ] a task that is long enough to wrap at this width for certain'
  coloured="$(mdr "$src")"
  bare="$(printf '%s\n' "$src" | PANEL_NO_COLOR=1 bash -c '. "$MD_RENDER_LIB"; md_render -')"
  assert_equal "$bare" "$coloured"
  [[ "$bare" != *$'\033'* ]] || fail "PANEL_NO_COLOR output still carries escape sequences"
}

# ── the contract with the caller ────────────────────────────────────────────

@test "a missing file fails loudly instead of rendering an empty pane" {
  # An empty pane reads as "this note is empty", which is the wrong answer to "that path does
  # not exist" -- and it is the answer a preview command gives silently.
  run md_render /does/not/exist.md
  assert_failure
  assert_output --partial 'no such file'
}

@test "a file argument and stdin render identically" {
  local f="$BATS_TEST_TMPDIR/note.md"
  printf -- '---\nid: x\n---\n\n## Now\n\nsome prose here\n' > "$f"
  assert_equal "$(md_render "$f")" "$(md_render - < "$f")"
}

@test "width follows FZF_PREVIEW_COLUMNS when MD_WIDTH is unset" {
  # The whole resize story: fzf exports it into every preview command, so the pane re-wraps
  # when the split moves with no extra plumbing.
  local long out
  long="$(printf 'alpha bravo charlie delta echo foxtrot %.0s' 1 2 3 4)"
  out="$(unset MD_WIDTH; FZF_PREVIEW_COLUMNS=40 mdr "$long" | awk 'length($0) > 38 { print }')"
  assert_equal "$out" ''
}
