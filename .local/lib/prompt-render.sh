# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather than a shebang.
#
# prompt-render.sh: a model call's instructions are a template file named by its conf's PROMPT
# (content is data, ~/.local/src/docs/layout.md), and the wrapper that makes the call fills in the
# run's values. One renderer, so every template means the same thing:
#
#   {{name}}             the value of the caller's shell variable `name`; an unset one is an error
#   {{#name}}..{{/name}}  the text between, kept only when `name` is not empty
#   {{^name}}..{{/name}}  the text between, kept only when `name` is empty
#   {{> path}}           the text of another file, relative to this one (its trailing newlines dropped)
#
# A value is never read as template: a row whose text holds `{{x}}` is passed as it is. A section
# cannot hold a section of the same name. The file's trailing newlines are dropped and a value's are
# kept, so `text)\n{{open}}` with an empty open ends in a newline, as the inline strings it replaces
# did. A caller reads it with prompt_render_into, since $(prompt_render) would drop that newline.
#
# prompt_sha is the version judge-eval scores a lane by (judges.md): the git blob hash of the file
# with its includes in place, so a file with no include hashes as `git hash-object` does, and a
# change to an included rule is a new prompt for every template that includes it.

PROMPT_INCLUDE_DEPTH=8

# prompt_expand <file> [depth]: the file's bytes with each {{> path}} replaced by that file's text.
prompt_expand() {
  local _pr_f="$1" _pr_d="${2:-0}" _pr_t="" _pr_out="" _pr_inc _pr_body
  [ -r "$_pr_f" ] && [ -f "$_pr_f" ] || { printf 'prompt: %s is not a readable file\n' "$_pr_f" >&2; return 1; }
  [ "$_pr_d" -le "$PROMPT_INCLUDE_DEPTH" ] || { printf 'prompt: %s: includes nest past %s (a cycle?)\n' "$_pr_f" "$PROMPT_INCLUDE_DEPTH" >&2; return 1; }
  IFS= read -r -d '' _pr_t <"$_pr_f" || true
  while [[ $_pr_t == *'{{>'* ]]; do
    _pr_out+="${_pr_t%%'{{>'*}"; _pr_t="${_pr_t#*'{{>'}"
    [[ $_pr_t == *'}}'* ]] || { printf 'prompt: %s: an include is not closed with }}\n' "$_pr_f" >&2; return 1; }
    _pr_inc="${_pr_t%%'}}'*}"; _pr_t="${_pr_t#*'}}'}"
    _pr_inc="${_pr_inc#"${_pr_inc%%[![:space:]]*}"}"; _pr_inc="${_pr_inc%"${_pr_inc##*[![:space:]]}"}"
    _pr_body="$(prompt_expand "$(dirname "$_pr_f")/$_pr_inc" "$((_pr_d + 1))")" || return 1
    _pr_out+="$_pr_body"
  done
  printf '%s' "$_pr_out$_pr_t"
}

# prompt_sha <file>: the git blob hash of the expanded file.
prompt_sha() {
  local _pr_x
  _pr_x="$(prompt_expand "$1" && printf x)" || return 1
  printf '%s' "${_pr_x%x}" | git hash-object --stdin
}

# prompt_render <file>: the template filled from the caller's variables, on stdout.
prompt_render() {
  local _pr_f="$1" _pr_t _pr_out="" _pr_tag _pr_n _pr_open=""
  _pr_t="$(prompt_expand "$_pr_f")" || return 1
  while [[ $_pr_t == *'{{'* ]]; do
    _pr_out+="${_pr_t%%'{{'*}"; _pr_t="${_pr_t#*'{{'}"
    [[ $_pr_t == *'}}'* ]] || { printf 'prompt: %s: a {{ is not closed with }}\n' "$_pr_f" >&2; return 1; }
    _pr_tag="${_pr_t%%'}}'*}"; _pr_t="${_pr_t#*'}}'}"
    _pr_n="${_pr_tag#[#^/]}"
    [[ $_pr_n =~ ^[a-z][a-z0-9_]*$ ]] || { printf 'prompt: %s: {{%s}} is not a variable name\n' "$_pr_f" "$_pr_tag" >&2; return 1; }
    if [ "${_pr_tag:0:1}" = / ]; then
      [ "${_pr_open##* }" = "$_pr_n" ] || { printf 'prompt: %s: {{/%s}} closes no open section\n' "$_pr_f" "$_pr_n" >&2; return 1; }
      _pr_open="${_pr_open% *}"; continue
    fi
    [ -n "${!_pr_n+x}" ] || { printf 'prompt: %s: {{%s}} has no value (no variable %s is set)\n' "$_pr_f" "$_pr_tag" "$_pr_n" >&2; return 1; }
    case "${_pr_tag:0:1}" in
      '#'|'^')
        if { [ "${_pr_tag:0:1}" = '#' ] && [ -n "${!_pr_n}" ]; } || { [ "${_pr_tag:0:1}" = '^' ] && [ -z "${!_pr_n}" ]; }; then
          _pr_open+=" $_pr_n"
        else
          [[ $_pr_t == *"{{/$_pr_n}}"* ]] || { printf 'prompt: %s: {{%s}} is not closed with {{/%s}}\n' "$_pr_f" "$_pr_tag" "$_pr_n" >&2; return 1; }
          _pr_t="${_pr_t#*"{{/$_pr_n}}"}"
        fi ;;
      *) _pr_out+="${!_pr_n}" ;;
    esac
  done
  [ -z "$_pr_open" ] || { printf 'prompt: %s: {{#%s}} is not closed\n' "$_pr_f" "${_pr_open##* }" >&2; return 1; }
  printf '%s' "$_pr_out$_pr_t"
}

# prompt_render_into <var> <file>: prompt_render's text, byte for byte, into the caller's <var>.
prompt_render_into() {
  local _pr_r
  _pr_r="$(prompt_render "$2" && printf x)" || return 1
  printf -v "$1" '%s' "${_pr_r%x}"
}

# prompt_has_vars <file>: does the expanded file hold a {{name}}, {{#name}} or {{^name}}? A
# template is filled by its caller and must never reach a model as it is.
prompt_has_vars() {
  local _pr_t
  _pr_t="$(prompt_expand "$1")" || return 2
  [[ $_pr_t =~ \{\{[#^/]?[a-z][a-z0-9_]*\}\} ]]
}
