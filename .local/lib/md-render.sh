# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather
# than a shebang (SC2148).
#
# md-render.sh - render a markdown note as readable terminal prose.
#
# WHY THIS EXISTS. Every surface that previewed a note piped it through `bat` inside an fzf
# window declared `wrap`, and that produced three separate unreadabilities at once:
#
#   * the note's MACHINERY on screen. YAML frontmatter, and the markers the tools address
#     each other with -- <!-- nextup:auto -->, <!-- STATUS:START -->, <!-- AUTO:START -->,
#     <!-- cockpit: vikunja=3 ... -->. Addressing, not content, and all of it rendered.
#   * fzf wrapping by COLUMN, which knows nothing about words, so prose broke mid-word
#     ("docu / ments", "develo / p") with fzf's wrap-sign glyph on every continuation.
#   * markdown left as SOURCE: `## Now`, `- [ ]`, `**bold**`, `[text](url)`.
#
# So the fix is not a nicer pager, it is rendering the note BEFORE fzf sees it. The preview
# window then needs no `wrap` at all, which is what removes the glyph and the cut words
# together -- they were the same bug.
#
# Not `glow` / `mdcat`: this has to work on every machine the dotfiles land on, it has to
# honour the house plain-ASCII rule (no general renderer does), and a sourced function is
# testable in the unit tier where a vendored binary is not.
#
# Lives in .local/lib rather than .local/src/tmux/panel-lib.sh because notes-cockpit.sh does
# not source panel-lib (it predates it and still carries its own palette), and this is the
# established shape for a library two unrelated consumers share -- same three-step lookup as
# agent-board.sh. panel-lib.sh wraps it as `panel_md` so panels keep the panel_* vocabulary.
#
# Usage:
#   . "$HOME/.local/lib/md-render.sh"
#   md_render <file>          # or `-` for stdin
#   MD_WIDTH=60 md_render -   # width override; otherwise FZF_PREVIEW_COLUMNS, else 80

# The palette, self-contained on purpose: the two consumers define identical C_* names, and
# reading the caller's would make this file's output depend on which one sourced it.
#
# HARD RULE, same as panel-lib.sh: ANSI indices 0-7 and 90 plus SGR attributes, NEVER
# 38;2;R;G;B or 38;5;N. Theme-switch recolours the terminal palette, so these follow a theme
# swap for free; a pinned hex would stop tracking it.
if [ -n "${PANEL_NO_COLOR:-${NO_COLOR:-}}" ]; then
  MD_C_HEAD='' MD_C_PROJ='' MD_C_DIM='' MD_C_BOX='' MD_C_OFF=''
else
  MD_C_HEAD=$'\033[1;37m' # heading (bold white)
  MD_C_PROJ=$'\033[1;35m' # sub-heading (magenta)
  MD_C_DIM=$'\033[90m'    # de-emphasis: rules, bullets, notes, done items
  MD_C_BOX=$'\033[36m'    # open checkbox (cyan)
  MD_C_OFF=$'\033[0m'
fi

# md_ascii -- stdin to stdout, Unicode punctuation folded to ASCII.
#
# The mapping is notes-version-summary's `sanitize()`, lifted here rather than copied a third
# time. iconv is the BACKSTOP, not the strategy: on its own it drops an em dash to NOTHING,
# joining the two words it separated. The named substitutions must run first.
md_ascii() {
  sed -E \
    -e 's/\xE2\x80\x94/ - /g' -e 's/\xE2\x80\x93/-/g' \
    -e "s/\xE2\x80\x98/'/g" -e "s/\xE2\x80\x99/'/g" \
    -e 's/\xE2\x80\x9C/"/g' -e 's/\xE2\x80\x9D/"/g' \
    -e 's/\xE2\x80\xA6/.../g' -e 's/\xE2\x86\x92/->/g' -e 's/\xE2\x86\x90/<-/g' \
    -e 's/\xE2\x80\xA2/-/g' -e 's/\xC2\xB7/-/g' -e 's/\xC2\xA0/ /g' |
    { iconv -c -f UTF-8 -t ASCII 2>/dev/null || cat; }
}

# md_render [file] -- the renderer. `-` or no argument reads stdin.
#
# WIDTH comes from fzf, which exports FZF_PREVIEW_COLUMNS into every preview command, so the
# pane re-wraps correctly when the split is resized with no extra plumbing. MD_WIDTH overrides
# it and is the seam the tests wrap at a known column.
#
# WRAPPING RUNS ON PLAIN TEXT; colour is applied to the finished row and nowhere else.
# Measuring a string that already carries \033[1;37m counts the escape toward the column
# budget, so every coloured line comes out short by the number of colour changes on it --
# invisibly, because the escapes do not print. Hence paint() at the very end.
md_render() {
  local src="${1:--}" w
  w="${MD_WIDTH:-${FZF_PREVIEW_COLUMNS:-80}}"
  case "$w" in '' | *[!0-9]*) w=80 ;; esac
  w=$((w - 2)) # a margin, so text never touches the pane border
  [ "$w" -lt 30 ] && w=30
  if [ "$src" != - ]; then
    [ -f "$src" ] || {
      printf 'md_render: no such file: %s\n' "$src" >&2
      return 1
    }
  fi
  # `cat --` rather than a redirect so a path beginning with `-` cannot become a flag, which
  # keeps the check above the only failure path.
  { if [ "$src" = - ]; then cat; else cat -- "$src"; fi; } | md_ascii | awk \
    -v W="$w" \
    -v HEAD="$MD_C_HEAD" -v PROJ="$MD_C_PROJ" -v DIM="$MD_C_DIM" \
    -v BOX="$MD_C_BOX" -v OFF="$MD_C_OFF" '
function repeat(c, n,   s) { s = ""; while (n-- > 0) s = s c; return s }

# The ONLY place colour is added. The first LEAD_N characters of the first row of a block
# carry LEAD_COL -- that one hook paints a bullet glyph, a checkbox and a bold lead-in alike,
# so there are not three near-identical painters that drift.
function paint(row, first,   head, rest) {
  if (first && LEAD_N > 0 && length(row) >= LEAD_N) {
    head = substr(row, 1, LEAD_N); rest = substr(row, LEAD_N + 1)
    printf "%s%s%s%s%s%s\n", LEAD_COL, head, OFF, BODY_COL, rest, (BODY_COL == "" ? "" : OFF)
  } else {
    printf "%s%s%s\n", BODY_COL, row, (BODY_COL == "" ? "" : OFF)
  }
}

# Blank runs collapse to one, a leading run to none. Deferred rather than printed on sight
# because stripping a marker turns its line blank, so the SOURCE blank count is not the
# rendered one -- three markers in a row would otherwise open the pane with three empty lines.
function flush_blank() { if (PEND && SEEN) print ""; PEND = 0 }

# A token with no space in it that is WIDER than the pane is hard-broken into pieces. This is
# the one case where there is nowhere to wrap, and the alternative is worse than a mid-token
# break: with the preview window no longer set to wrap, an overlong line is TRUNCATED and the tail
# disappears with nothing to say it did. Rendering every real note found one: a 67-character
# `SOME_PUBLIC_FEATURE_FLAG_ENABLED/extra.someFeatureFlagEnabled`-shaped identifier, which a
# synthetic fixture would never have produced.
function chop(text, avail,   n, w, i, t, out) {
  n = split(text, w, " ")
  for (i = 1; i <= n; i++) {
    t = w[i]
    while (length(t) > avail) {
      out = out (out == "" ? "" : " ") substr(t, 1, avail)
      t = substr(t, avail + 1)
    }
    out = out (out == "" ? "" : " ") t
  }
  return out
}

# Word wrap. ind1 opens the block and ind2 hangs every continuation under the TEXT, which is
# what keeps a wrapped checklist item reading as one item instead of two.
function emit(text, ind1, ind2, leadn, leadcol, bodycol,   n, word, i, cur, curlen, first, avail) {
  LEAD_N = leadn; LEAD_COL = leadcol; BODY_COL = bodycol
  gsub(/[ \t]+/, " ", text); sub(/^ +/, "", text); sub(/ +$/, "", text)
  if (text == "") return
  flush_blank()
  avail = W - length(ind2)
  if (avail < 8) avail = 8
  text = chop(text, avail)
  n = split(text, word, " ")
  cur = ind1 word[1]; curlen = length(cur); first = 1
  for (i = 2; i <= n; i++) {
    if (curlen + 1 + length(word[i]) > W) {
      paint(cur, first); first = 0
      cur = ind2 word[i]; curlen = length(cur)
    } else {
      cur = cur " " word[i]; curlen += 1 + length(word[i])
    }
  }
  paint(cur, first)
  SEEN = 1
}

function rule(n) { flush_blank(); printf "%s%s%s\n", DIM, repeat("-", n), OFF; SEEN = 1 }

# Inline markup, stripped BEFORE the text is measured so a marker never occupies a column.
#
# `_` is handled at the START of a line ONLY, and deliberately: these notes are full of
# snake_case identifiers (billing_notes, care_document) and a global strip mangles every one
# of them. Every italic run actually written here is either a lead-in (`_2026-07-06_ - ...`)
# or wraps the whole line, and both are the leading case.
function inline(s,   t, p) {
  while (match(s, /\[[^][]*\]\([^()]*\)/)) {          # [text](url) -> text
    t = substr(s, RSTART, RLENGTH)
    sub(/^\[/, "", t); sub(/\]\(.*$/, "", t)
    s = substr(s, 1, RSTART - 1) t substr(s, RSTART + RLENGTH)
  }
  gsub(/`/, "", s)
  gsub(/\*\*/, "", s)
  if (substr(s, 1, 1) == "_") {
    p = index(substr(s, 2), "_")
    if (p > 0) s = substr(s, 2, p - 1) substr(s, p + 2)
  }
  return s
}

BEGIN { if (W < 30) W = 30 }

{
  line = $0

  # Frontmatter, only when it OPENS the file -- a `---` anywhere else is a horizontal rule.
  if (NR == 1 && line ~ /^---[ \t]*$/) { FM = 1; next }
  if (FM) { if (line ~ /^---[ \t]*$/) FM = 0; next }

  if (CODE) {
    if (line ~ /^[ \t]*```/) { CODE = 0; next }
    flush_blank(); printf "%s  %s%s\n", DIM, line, OFF; SEEN = 1; next
  }

  # HTML comments. Scanned with index() rather than a regex because a marker may itself
  # contain `>` (<!-- cockpit: ... branch=develop -->), and /<!--[^>]*-->/ stops at it.
  if (COM) {
    p = index(line, "-->")
    if (p == 0) next
    line = substr(line, p + 3); COM = 0
  }
  while ((a = index(line, "<!--")) > 0) {
    rest = substr(line, a + 4); b = index(rest, "-->")
    if (b > 0) { line = substr(line, 1, a - 1) substr(rest, b + 3) }
    else { line = substr(line, 1, a - 1); COM = 1; break }
  }

  if (line ~ /^[ \t]*```/) { CODE = 1; next }
  if (line ~ /^[ \t]*$/) { PEND = 1; next }
  if (line ~ /^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$/) { rule(W); next }

  # A table keeps its grid: wrapping a row destroys the columns that make it a table.
  if (line ~ /^[ \t]*\|/) { flush_blank(); LEAD_N = 0; BODY_COL = ""; print substr(inline(line), 1, W); SEEN = 1; next }

  if (match(line, /^#+[ \t]+/)) {
    t = substr(line, RLENGTH + 1)
    lvl = 0; while (substr(line, lvl + 1, 1) == "#") lvl++
    sub(/^(->|<-)[ \t]*/, "", t)        # a sanitized arrow heading: `## -> For the agents`
    sub(/[ \t]+#*[ \t]*$/, "", t)
    t = inline(t)
    PEND = 1                            # a heading always gets air above it
    if (lvl <= 2) {
      emit(toupper(t), "", "", 0, "", HEAD)
      if (lvl == 1) rule(length(t) + 4 > W ? W : length(t) + 4)
    } else {
      emit(t, "  ", "  ", 0, "", PROJ)
    }
    next
  }

  # `- [ ] task` -> `  [ ] task`, continuations hanging at the text column.
  if (match(line, /^[ \t]*[-*+][ \t]+\[[ xX]\][ \t]*/)) {
    t = substr(line, RLENGTH + 1)
    done = (line ~ /\[[xX]\]/)
    emit(inline(t), (done ? "  [x] " : "  [ ] "), "      ", 5, (done ? DIM : BOX), (done ? DIM : ""))
    next
  }

  if (match(line, /^[ \t]*[-*+][ \t]+/)) {
    pre = RLENGTH
    ws = line; sub(/[^ \t].*$/, "", ws); gsub(/\t/, "  ", ws)
    depth = int(length(ws) / 2); if (depth > 3) depth = 3
    ind = "  " repeat("  ", depth)
    emit(inline(substr(line, pre + 1)), ind "- ", ind "  ", length(ind) + 1, DIM, "")
    next
  }

  if (match(line, /^[ \t]*>[ \t]?/)) { emit(inline(substr(line, RLENGTH + 1)), "  ", "  ", 0, "", DIM); next }

  # Prose. A line that is ENTIRELY bold is a sub-heading in every note this renders
  # (**Shipping next**, **In progress**); one entirely italic is an editorial aside. A run
  # that merely OPENS a line keeps its emphasis through LEAD_N.
  #
  # Bold that STRADDLES a wrap is deliberately not attempted: once the line is measured the
  # marker positions are gone, and a half-open SGR bleeding down the pane is worse than no
  # bold at all.
  #
  # The lead run is measured through inline() rather than by its position in the SOURCE.
  # A feed line like ``**shipped `myapp-v1.11.0`**`` is 2 characters longer before the
  # backticks are stripped than after, so a raw offset paints the start of the following
  # text bold too.
  bodycol = ""; lead = 0; leadcol = ""
  if (line ~ /^\*\*.*\*\*$/ && index(substr(line, 3, length(line) - 4), "**") == 0) bodycol = PROJ
  else if (line ~ /^_[^_]+_$/) bodycol = DIM
  else if (substr(line, 1, 2) == "**") { p = index(substr(line, 3), "**"); if (p > 0) { lead = length(inline(substr(line, 3, p - 1))); leadcol = HEAD } }
  else if (substr(line, 1, 1) == "_") { p = index(substr(line, 2), "_"); if (p > 0) { lead = length(inline(substr(line, 2, p - 1))); leadcol = DIM } }
  emit(inline(line), "  ", "  ", (lead > 0 ? lead + 2 : 0), leadcol, bodycol)
}
'
}
