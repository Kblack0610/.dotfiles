#!/usr/bin/env bats
# .local/lib/prompt-render.sh: the one renderer every prompt template goes through, and the sha
# judge-eval scores a prompt version by (~/.local/src/docs/judges.md).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.local/lib/prompt-render.sh"
  T="$SANDBOX/tpl"
  mkdir -p "$T/rules"
}

@test "a variable is filled with its value as text: & and backslashes and {{ in a value stay as they are" {
  printf 'Row: {{line}}.\n' > "$T/p.md"
  line='a & b \1 {{other}}'
  run prompt_render "$T/p.md"
  assert_success
  assert_output 'Row: a & b \1 {{other}}.'
}

@test "the rendered text keeps the file's inner newlines and drops its trailing one" {
  printf 'one\n\ntwo {{x}}\n' > "$T/p.md"
  x=X
  assert_equal "$(prompt_render "$T/p.md"; printf '|')" "$(printf 'one\n\ntwo X|')"
}

@test "prompt_render_into keeps the newline an empty last value leaves, as \$(...) would not" {
  printf 'rows:\n{{open}}\n' > "$T/p.md"
  open=""
  prompt_render_into got "$T/p.md"
  assert_equal "$got|" "$(printf 'rows:\n|')"
}

@test "a section is kept when its variable is not empty, an inverted one when it is" {
  printf 'a{{#on}} on={{on}}{{/on}}{{^on}} off{{/on}} b{{#off}} gone{{/off}}{{^off}} kept{{/off}}.\n' > "$T/p.md"
  on=yes off=""
  run prompt_render "$T/p.md"
  assert_output 'a on=yes b kept.'
}

@test "an include is the other file's text in place, relative to the including file" {
  printf 'Rule {{n}}.\n\n' > "$T/rules/r.md"
  printf 'Head.\n{{> rules/r.md}}\nTail.\n' > "$T/p.md"
  n=1
  run prompt_render "$T/p.md"
  assert_output "$(printf 'Head.\nRule 1.\nTail.')"
}

@test "an unset variable is an error, an empty one is not (negative control)" {
  printf 'x {{missing}}\n' > "$T/p.md"
  unset missing
  run prompt_render "$T/p.md"
  assert_failure
  assert_output --partial 'has no value'
  missing=""
  run prompt_render "$T/p.md"
  assert_success
  assert_output 'x '
}

@test "an unclosed section, a stray close and a bad name are errors (negative control)" {
  v=1
  printf '{{#v}} open\n' > "$T/p.md"
  run prompt_render "$T/p.md"; assert_failure
  printf 'close {{/v}}\n' > "$T/p.md"
  run prompt_render "$T/p.md"; assert_failure
  printf '{{_pr_f}}\n' > "$T/p.md"
  run prompt_render "$T/p.md"; assert_failure
  assert_output --partial 'is not a variable name'
}

@test "an include cycle stops at the depth cap (negative control)" {
  printf '{{> b.md}}\n' > "$T/a.md"; printf '{{> a.md}}\n' > "$T/b.md"
  run prompt_expand "$T/a.md"
  assert_failure
  assert_output --partial 'nest past'
}

@test "prompt_sha is git's blob hash for a file with no include, and moves when an included file changes" {
  printf 'Plain {{x}}.\n' > "$T/plain.md"
  assert_equal "$(prompt_sha "$T/plain.md")" "$(git hash-object "$T/plain.md")"
  printf 'v1\n' > "$T/rules/r.md"; printf 'Top\n{{> rules/r.md}}\n' > "$T/p.md"
  before="$(prompt_sha "$T/p.md")"
  printf 'v2\n' > "$T/rules/r.md"
  refute [ "$(prompt_sha "$T/p.md")" = "$before" ]
}

@test "prompt_has_vars tells a template from plain text, through includes" {
  printf 'Plain text {not a var}.\n' > "$T/plain.md"
  run prompt_has_vars "$T/plain.md"; assert_failure
  printf '{{#x}}y{{/x}}\n' > "$T/rules/r.md"; printf '{{> rules/r.md}}\n' > "$T/p.md"
  run prompt_has_vars "$T/p.md"; assert_success
}
