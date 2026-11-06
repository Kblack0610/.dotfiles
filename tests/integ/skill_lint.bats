#!/usr/bin/env bats
# skill-drift --lint: the STATIC checks, which are the ones CI can run.
#
# A CI runner has no ~/.claude/skills, no private overlay and no CLAUDE.md, so the
# environmental checks (DEADPATH, NOCMD, UNDEPLOYED, GHOST, STALE, UNUSED, LISTBUDGET)
# cannot even be attempted there. --lint is the subset decidable from a checkout, and
# this file is the proof that each check FAILS on a bad skill rather than waving it
# through - a lint nobody has watched fail is a lint nobody should trust.
#
# Every test here is a negative control by construction: build a deliberately broken
# skill, assert the specific finding. The two positive tests at the end guard the
# other direction (a valid corpus must pass, and an EMPTY corpus must NOT).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DRIFT="$REPO_ROOT/.local/bin/skill-drift"
  REPO="$HOME/repo"
  mkdir -p "$REPO/.claude/skills"
  export DRIFT REPO
  # An empty baseline: these fixtures carry no legacy ASCII debt, so nothing is
  # grandfathered and NONASCII is a hard error like everything else.
  export SKILL_LINT_BASELINE="$HOME/empty.baseline"
  : > "$SKILL_LINT_BASELINE"
}

# mkskill <category> <name> [extra-frontmatter-lines...]
mkskill() {
  local cat="$1" name="$2"; shift 2
  local d="$REPO/.claude/skills/$cat/$name"
  mkdir -p "$d"
  {
    echo "---"
    echo "name: $name"
    echo "description: A test skill. Use when testing."
    echo "metadata:"
    echo "  category: $cat"
    echo "  tags: [testing]"
    echo '  reviewed: "2026-08-01"'
    for line in "$@"; do echo "$line"; done
    echo "---"
    echo
    echo "## Scope and triggers"
    echo
    echo "- when testing"
  } > "$d/SKILL.md"
  printf '%s' "$d"
}

lint() { run "$DRIFT" --lint "$REPO"; }

# ── the corpus must pass when it is actually valid ───────────────────────────

@test "a well-formed corpus passes" {
  mkskill ops one >/dev/null
  mkskill memory two >/dev/null
  lint
  assert_success
  assert_output --partial "2 skill(s) valid"
}

# The single most important test in this file. Every tooling failure in this repo
# has been a silent success, and a linter that scans nothing and reports "valid" is
# the purest example. Exit 2, not 0.
@test "an EMPTY corpus is a failure, not a clean run" {
  lint
  assert_failure 2
  assert_output --partial "refusing to report success"
}

# ── each static check must actually fire ─────────────────────────────────────

@test "NOFRONTMATTER: a SKILL.md with no frontmatter" {
  d=$(mkskill ops broken)
  printf '# just a heading\n' > "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NOFRONTMATTER"
}

@test "NOFRONTMATTER: frontmatter without a description" {
  d=$(mkskill ops nodesc)
  printf -- '---\nname: nodesc\n---\n\n## Scope and triggers\n' > "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NOFRONTMATTER"
  assert_output --partial "missing description"
}

@test "BADNAME: name is not kebab-case" {
  d=$(mkskill ops Bad_Name)
  lint
  assert_failure
  assert_output --partial "BADNAME"
  assert_output --partial "not kebab-case"
}

@test "BADNAME: frontmatter name disagrees with the directory" {
  d=$(mkskill ops realdir)
  sed -i 's/^name: realdir/name: someothername/' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADNAME"
  assert_output --partial "does not match the directory"
}

@test "DUPNAME: the same skill name in two categories" {
  mkskill ops twice >/dev/null
  mkskill memory twice >/dev/null
  lint
  assert_failure
  assert_output --partial "DUPNAME"
}

@test "BADMETA: missing category" {
  d=$(mkskill ops nocat)
  sed -i '/^  category:/d' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "missing metadata.category"
}

@test "BADMETA: a category outside the known set" {
  mkskill wizardry spells >/dev/null
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "not one of"
}

@test "BADMETA: category disagrees with the parent directory" {
  d=$(mkskill ops liar)
  sed -i 's/^  category: ops/  category: memory/' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "disagrees with the parent directory"
}

@test "BADMETA: missing reviewed date" {
  d=$(mkskill ops norev)
  sed -i '/^  reviewed:/d' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "missing metadata.reviewed"
}

@test "BADMETA: a reviewed date that is not YYYY-MM-DD" {
  d=$(mkskill ops badrev)
  sed -i 's/^  reviewed:.*/  reviewed: "last tuesday"/' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "YYYY-MM-DD"
}

@test "BADMETA: missing tags" {
  d=$(mkskill ops notags)
  sed -i '/^  tags:/d' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADMETA"
  assert_output --partial "missing metadata.tags"
}

@test "CATCOLLIDE: a category sharing a name with a skill" {
  # This is not hypothetical: comms/comms/ made `git mv` refuse and silently
  # swallowed two sibling skills during the category migration.
  mkskill ops memory >/dev/null      # a skill called "memory"
  mkskill memory realskill >/dev/null # and a category called "memory"
  lint
  assert_failure
  assert_output --partial "CATCOLLIDE"
}

# desc <bytes>: a plain description of exactly that many bytes.
desc() { printf 'x%.0s' $(seq 1 "$1"); }

@test "LONGDESC: a 301-byte description fails" {
  d=$(mkskill ops verbose)
  sed -i "s/^description: .*/description: $(desc 301)/" "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "LONGDESC"
  assert_output --partial "301B"
}

@test "LONGDESC: a 300-byte description passes" {
  d=$(mkskill ops exact)
  sed -i "s/^description: .*/description: $(desc 300)/" "$d/SKILL.md"
  lint
  assert_success
}

# A folded block counts its folded value, not its raw lines. Six 49-byte lines
# fold to 299 bytes (6*49 plus 5 joining spaces) while the raw block, with its
# indent and newlines, is over 310: a raw-line counter fails a skill that fits.
# mkfolded <dir> <lines> <width> <style>
mkfolded() {
  local d="$1" n="$2" w="$3" style="$4" line
  line=$(desc "$w")
  python3 - "$d/SKILL.md" "$line" "$style" "$n" <<'PY'
import sys
p, line, style, n = sys.argv[1:]
s = open(p).read()
block = "description: " + style + "\n" + "".join("  " + line + "\n" for _ in range(int(n)))
s = s.replace(next(l for l in s.split("\n") if l.startswith("description:")) + "\n", block)
open(p, "w").write(s)
PY
}

@test "LONGDESC: a >- block under the cap passes on its folded value" {
  d=$(mkskill ops folded)
  mkfolded "$d" 6 49 '>-'
  lint
  assert_success
}

@test "LONGDESC: a >- block over the cap fails on its folded value" {
  d=$(mkskill ops foldedlong)
  mkfolded "$d" 4 75 '>-'
  lint
  assert_failure
  assert_output --partial "LONGDESC"
  assert_output --partial "303B"
}

# A literal block keeps its newlines: the same four 75-byte lines are 304 bytes
# under `|` (each line plus its newline) where `>-` gave 303.
@test "LONGDESC: a | block counts its kept newlines" {
  d=$(mkskill ops literal)
  mkfolded "$d" 4 75 '|'
  lint
  assert_failure
  assert_output --partial "304B"
}

@test "NONASCII: an em dash trips the house plain-ASCII rule" {
  d=$(mkskill ops fancy)
  printf 'Some prose with an em dash \xe2\x80\x94 right here.\n' >> "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NONASCII"
}

@test "NONASCII: an arrow and an ellipsis too" {
  d=$(mkskill ops arrows)
  printf 'Flow: a \xe2\x86\x92 b, and so on\xe2\x80\xa6\n' >> "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NONASCII"
}

@test "NONASCII is suppressed for a skill named in the baseline" {
  d=$(mkskill ops legacy)
  printf 'Prose with an em dash \xe2\x80\x94 here.\n' >> "$d/SKILL.md"
  echo "NONASCII|legacy" > "$SKILL_LINT_BASELINE"
  lint
  assert_success
}

@test "the baseline suppresses only the skill it names" {
  d1=$(mkskill ops legacy); d2=$(mkskill ops fresh)
  printf 'em dash \xe2\x80\x94 here\n' >> "$d1/SKILL.md"
  printf 'em dash \xe2\x80\x94 here\n' >> "$d2/SKILL.md"
  echo "NONASCII|legacy" > "$SKILL_LINT_BASELINE"
  lint
  assert_failure
  assert_output --partial "fresh"
  refute_output --partial "FAIL  NONASCII      legacy"
}

@test "NOHEADING: a skill without the required heading fails" {
  d=$(mkskill ops headless)
  sed -i '/^## Scope and triggers/d' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NOHEADING"
}

@test "NOHEADING: a When to Use heading does not stand in for it" {
  d=$(mkskill ops oldstyle)
  sed -i 's/^## Scope and triggers/## When to Use/' "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "NOHEADING"
}

@test "NOHEADING: a frozen finding passes" {
  d=$(mkskill ops headless)
  sed -i '/^## Scope and triggers/d' "$d/SKILL.md"
  echo "NOHEADING|headless" > "$SKILL_LINT_BASELINE"
  lint
  assert_success
}

# ── the baseline holds old debt only, and says when a line has gone stale ─────

@test "the baseline cannot freeze a check that was clean when it landed" {
  d=$(mkskill ops verbose)
  sed -i "s/^description: .*/description: $(desc 301)/" "$d/SKILL.md"
  echo "LONGDESC|verbose" > "$SKILL_LINT_BASELINE"
  lint
  assert_failure
  assert_output --partial "LONGDESC"
}

@test "--write-lint-baseline freezes every frozen-eligible finding and no other" {
  d=$(mkskill ops debtor)
  sed -i '/^## Scope and triggers/d' "$d/SKILL.md"
  printf 'em dash \xe2\x80\x94 here\n' >> "$d/SKILL.md"
  mkentry commands "my/go" "description: \"$(desc 301)\""
  d=$(mkskill ops verbose)
  sed -i "s/^description: .*/description: $(desc 301)/" "$d/SKILL.md"
  run "$DRIFT" --write-lint-baseline "$REPO"
  assert_success
  run cat "$SKILL_LINT_BASELINE"
  assert_output "LONGDESC|command:my/go
NOHEADING|debtor
NONASCII|debtor"
}

@test "a stale baseline line is reported and does not fail the lint" {
  mkskill ops fixed >/dev/null
  echo "NOHEADING|fixed" > "$SKILL_LINT_BASELINE"
  lint
  assert_success
  assert_output --partial "stale baseline line, delete it: NOHEADING|fixed"
}

@test "a baseline line with live debt is not called stale" {
  d=$(mkskill ops headless)
  sed -i '/^## Scope and triggers/d' "$d/SKILL.md"
  echo "NOHEADING|headless" > "$SKILL_LINT_BASELINE"
  lint
  assert_success
  refute_output --partial "stale"
}

# ── --ratchet: the baseline only shrinks ─────────────────────────────────────
#
# A real repo with a real merge base, because that comparison is the whole check.
# ratchet_repo <baseline-lines>: main holds them, HEAD is a branch off it.
ratchet_repo() {
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name t
  git -C "$REPO" config user.email t@example.com
  mkdir -p "$REPO/tests"
  printf '%s' "$1" > "$REPO/tests/skill-lint.baseline"
  git -C "$REPO" add tests
  git -C "$REPO" commit -qm base
  git -C "$REPO" checkout -qb work
}

# The baseline under test is the repo's own, so drop the suite's empty one.
ratchet() { SKILL_LINT_BASELINE="" run "$DRIFT" --ratchet "$REPO" main; }

commit_baseline() {
  printf '%s' "$1" > "$REPO/tests/skill-lint.baseline"
  git -C "$REPO" commit -qam "${2:-change the baseline}"
}

@test "--ratchet: an added baseline line fails" {
  ratchet_repo $'NONASCII|old\n'
  commit_baseline $'NONASCII|new\nNONASCII|old\n'
  ratchet
  assert_failure 1
  assert_output --partial "ADDED  NONASCII|new"
  refute_output --partial "ADDED  NONASCII|old"
}

@test "--ratchet: an unchanged or shorter baseline passes" {
  ratchet_repo $'NONASCII|a\nNONASCII|b\n'
  ratchet
  assert_success
  commit_baseline $'NONASCII|a\n'
  ratchet
  assert_success
}

@test "--ratchet: a line added to an EMPTY baseline fails, so a drained one stays drained" {
  ratchet_repo ''
  commit_baseline $'NONASCII|new\n'
  ratchet
  assert_failure 1
}

@test "--ratchet: a baseline the merge base never had counts every line as added" {
  ratchet_repo $'NONASCII|a\n'
  git -C "$REPO" checkout -q main
  git -C "$REPO" rm -q tests/skill-lint.baseline
  git -C "$REPO" commit -qm 'drop it'
  git -C "$REPO" checkout -qB work
  mkdir -p "$REPO/tests"
  printf 'NONASCII|a\n' > "$REPO/tests/skill-lint.baseline"
  git -C "$REPO" add tests
  git -C "$REPO" commit -qm 'first freeze'
  ratchet
  assert_failure 1
}

@test "--ratchet: a line main dropped after the branch was cut is not an added line" {
  ratchet_repo $'NONASCII|a\nNONASCII|b\n'
  git -C "$REPO" checkout -q main
  commit_baseline $'NONASCII|a\n'
  git -C "$REPO" checkout -q work
  ratchet
  assert_success
}

@test "--ratchet: a Skill-Baseline-Raise trailer allows the line and prints why" {
  ratchet_repo ''
  commit_baseline $'NOHEADING|old\n' $'freeze\n\nSkill-Baseline-Raise: a new check has debt to freeze'
  ratchet
  assert_success
  assert_output --partial "a new check has debt to freeze"
}

@test "--ratchet: the word in a commit body is not a trailer" {
  ratchet_repo ''
  commit_baseline $'NOHEADING|old\n' $'freeze\n\nSkill-Baseline-Raise: in a paragraph\nthat goes on in prose, which is no trailer block.'
  ratchet
  assert_failure 1
}

@test "--ratchet: an unknown base is exit 2, never a pass" {
  ratchet_repo $'NONASCII|a\n'
  SKILL_LINT_BASELINE="" run "$DRIFT" --ratchet "$REPO" no-such-ref
  assert_failure 2
  assert_output --partial "refusing to report success"
}

# ── commands and agents ──────────────────────────────────────────────────────

# mkentry <commands|agents> <path-without-.md> <frontmatter-line>...
mkentry() {
  local kind="$1" rel="$2"; shift 2
  local f="$REPO/.claude/$kind/$rel.md"
  mkdir -p "$(dirname "$f")"
  {
    echo "---"
    for line in "$@"; do echo "$line"; done
    echo "---"
    echo
    echo "Body."
  } > "$f"
}

@test "a valid command and agent pass, and alone they are not an empty corpus" {
  mkentry commands my/go "description: Proceed at this checkpoint."
  mkentry agents reviewer "name: reviewer" "description: Reviews a diff."
  lint
  assert_success
  assert_output --partial "2 command or agent file(s)"
}

@test "a command with no description fails" {
  mkskill ops one >/dev/null
  mkentry commands my/go "allowed-tools: Bash"
  lint
  assert_failure
  assert_output --partial "command:my/go"
  assert_output --partial "missing description"
}

@test "an agent with no description fails" {
  mkskill ops one >/dev/null
  mkentry agents reviewer "name: reviewer"
  lint
  assert_failure
  assert_output --partial "agent:reviewer"
  assert_output --partial "missing description"
}

@test "an agent with no name fails, a command needs none" {
  mkskill ops one >/dev/null
  mkentry agents reviewer "description: Reviews a diff."
  mkentry commands go "description: Go."
  lint
  assert_failure
  assert_output --partial "agent:reviewer"
  assert_output --partial "missing name"
  refute_output --partial "command:go"
}

@test "a command with no frontmatter fails once, on that" {
  mkskill ops one >/dev/null
  mkdir -p "$REPO/.claude/commands"
  printf '# prose: with a colon\nmore: prose\n' > "$REPO/.claude/commands/bare.md"
  lint
  assert_failure
  assert_output --partial "NOFRONTMATTER"
  refute_output --partial "BADYAML"
}

@test "a command with unparseable frontmatter fails" {
  mkskill ops one >/dev/null
  mkentry commands daily/report "description: x" "argument-hint: [--a?] [--b?]"
  lint
  assert_failure
  assert_output --partial "BADYAML"
}

@test "a description over the budget fails on a command and an agent" {
  mkskill ops one >/dev/null
  mkentry commands long "description: $(desc 301)"
  mkentry agents wordy "name: wordy" "description: $(desc 301)"
  lint
  assert_failure
  assert_output --regexp 'LONGDESC +agent:wordy'
  assert_output --regexp 'LONGDESC +command:long'
}

@test "non-ASCII fails in a command and in an agent" {
  mkskill ops one >/dev/null
  mkentry commands dashy "description: x"
  mkentry agents dashy "name: dashy" "description: x"
  printf 'em dash \xe2\x80\x94 here\n' >> "$REPO/.claude/commands/dashy.md"
  printf 'em dash \xe2\x80\x94 here\n' >> "$REPO/.claude/agents/dashy.md"
  lint
  assert_failure
  assert_output --regexp 'NONASCII +agent:dashy'
  assert_output --regexp 'NONASCII +command:dashy'
}

@test "command and agent debt freezes through the baseline, by file" {
  mkentry commands legacy "allowed-tools: Bash"
  mkentry commands fresh "allowed-tools: Bash"
  echo "NOFRONTMATTER|command:legacy" > "$SKILL_LINT_BASELINE"
  lint
  assert_failure
  assert_output --partial "command:fresh"
  refute_output --partial "command:legacy"
}

# ── --profile project: a game repo's flat skills ─────────────────────────────

# mkflat <name> [extra-body-line]: the frontmatter a game repo has, no metadata block.
mkflat() {
  local d="$REPO/.claude/skills/$1"
  mkdir -p "$d"
  printf -- '---\nname: %s\ndescription: A project skill.\n---\n\n## Scope and triggers\n\n%s\n' "$1" "${2:-Body.}" > "$d/SKILL.md"
  printf '%s' "$d"
}

project() { run "$DRIFT" --lint "$REPO" --profile project; }

@test "project profile: a flat skill with no metadata passes, and full refuses it" {
  mkflat build >/dev/null
  project
  assert_success
  assert_output --partial "1 skill(s) valid"
  lint
  assert_failure
  assert_output --partial "BADMETA"
}

@test "project profile: a category outside the dotfiles set is no finding" {
  mkskill gameplay spawn >/dev/null
  project
  assert_success
}

@test "project profile: a bad heading fails" {
  d=$(mkflat build)
  sed -i '/^## Scope and triggers/d' "$d/SKILL.md"
  project
  assert_failure
  assert_output --partial "NOHEADING"
}

@test "project profile: name, description budget and ASCII still hold" {
  d=$(mkflat build)
  sed -i 's/^name: build/name: other/' "$d/SKILL.md"
  d=$(mkflat wordy)
  sed -i "s/^description: .*/description: $(desc 301)/" "$d/SKILL.md"
  mkflat dashy $'em dash \xe2\x80\x94 here' >/dev/null
  mkdir -p "$REPO/.claude/skills/nodesc"
  printf -- '---\nname: nodesc\n---\n\n## Scope and triggers\n' > "$REPO/.claude/skills/nodesc/SKILL.md"
  project
  assert_failure
  assert_output --partial "BADNAME"
  assert_output --partial "LONGDESC"
  assert_output --partial "NONASCII"
  assert_output --partial "NOFRONTMATTER"
}

@test "project profile: commands and agents are linted too" {
  mkflat build >/dev/null
  mkentry commands go "allowed-tools: Bash"
  project
  assert_failure
  assert_output --partial "command:go"
}

@test "project profile: an empty corpus is still a failure" {
  project
  assert_failure 2
}

@test "--write-lint-baseline honours the profile" {
  mkflat build >/dev/null
  d=$(mkflat headless)
  sed -i '/^## Scope and triggers/d' "$d/SKILL.md"
  run "$DRIFT" --write-lint-baseline "$REPO" --profile project
  assert_success
  project
  assert_success
}

@test "an unknown profile is exit 2, never another contract" {
  mkskill ops one >/dev/null
  run "$DRIFT" --lint "$REPO" --profile fulll
  assert_failure 2
  assert_output --partial "unknown profile"
}

# ── the flat layout still lints, so the gate works before AND after a migration ──

@test "a flat skill (no category dir) still gets its frontmatter checked" {
  d="$REPO/.claude/skills/flatty"
  mkdir -p "$d"
  printf -- '---\nname: WRONG\ndescription: x\n---\n\n## Scope and triggers\n' > "$d/SKILL.md"
  lint
  assert_failure
  assert_output --partial "BADNAME"
}

# ── UNUSED reads claude-recall stats ─────────────────────────────────────────
#
# A skill reached only by its typed /command was reported unused while the counter was
# a grep for Skill-tool calls. Three deployed skills: one run by the Skill tool, one only
# typed as a /command, one never touched.
@test "UNUSED: a skill typed as a /command counts as used; an untouched one is reported" {
  mkdir -p "$HOME/empty/pub" "$HOME/empty/priv" "$HOME/empty/tx/-p"
  : > "$HOME/empty/CLAUDE.md"
  for s in by-tool by-slash idle; do
    mkdir -p "$HOME/empty/skills/$s"
    printf -- '---\nname: %s\ndescription: x\n---\n' "$s" > "$HOME/empty/skills/$s/SKILL.md"
  done
  ts="\"timestamp\":\"$(date -u +%FT%TZ)\""
  cat > "$HOME/empty/tx/-p/s.jsonl" <<JSONL
{"type":"user","turnOrigin":"human","cwd":"/p",$ts,"message":{"role":"user","content":"<command-name>/by-slash</command-name>"}}
{"type":"assistant","cwd":"/p",$ts,"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"by-tool"}}]}}
JSONL
  CLAUDE_SKILLS="$HOME/empty/skills" DOTFILES="$HOME/empty/pub" \
  DOTFILES_PRIVATE="$HOME/empty/priv" \
  CLAUDE_MD="$HOME/empty/CLAUDE.md" CLAUDE_TRANSCRIPTS="$HOME/empty/tx" \
  SKILL_DRIFT_BASELINE="$HOME/empty/baseline" \
    run "$DRIFT"
  assert_output --regexp 'UNUSED +idle '
  refute_output --regexp 'UNUSED +by-slash '
  refute_output --regexp 'UNUSED +by-tool '
}

# ── LISTBUDGET: the whole listing, over the deployed tree ────────────────────
#
# Environmental, so it runs in the report, and --lint never sees it.

# mkdeployed <name> <frontmatter-line>...
mkdeployed() {
  local d="$HOME/empty/skills/$1"; shift
  mkdir -p "$d"
  {
    echo "---"
    echo "name: $(basename "$d")"
    for line in "$@"; do echo "$line"; done
    echo "---"
  } > "$d/SKILL.md"
}

# listing_report <budget>: a deployed tree in the sandbox and nothing else.
listing_report() {
  mkdir -p "$HOME/empty/skills" "$HOME/empty/pub" "$HOME/empty/priv" "$HOME/empty/tx" "$HOME/empty/commands"
  : > "$HOME/empty/CLAUDE.md"
  CLAUDE_SKILLS="$HOME/empty/skills" CLAUDE_COMMANDS="$HOME/empty/commands" \
  DOTFILES="$HOME/empty/pub" DOTFILES_PRIVATE="$HOME/empty/priv" \
  CLAUDE_MD="$HOME/empty/CLAUDE.md" CLAUDE_TRANSCRIPTS="$HOME/empty/tx" \
  SKILL_DRIFT_BASELINE="$HOME/empty/baseline" SKILL_LISTING_MAX="$1" \
    run "$DRIFT" "${@:2}"
}

@test "LISTBUDGET: a listing over the budget reports its size" {
  mkdeployed big "description: $(desc 200)"
  mkdeployed bigger "description: $(desc 200)"
  listing_report 400
  assert_output --regexp 'LISTBUDGET +listing +419B'
}

@test "LISTBUDGET: a listing inside the budget does not report" {
  mkdeployed big "description: $(desc 200)"
  listing_report 400
  refute_output --partial "LISTBUDGET"
}

@test "LISTBUDGET: commands share the listing" {
  mkdeployed big "description: $(desc 200)"
  mkdir -p "$HOME/empty/commands/my"
  printf -- '---\ndescription: %s\n---\n' "$(desc 200)" > "$HOME/empty/commands/my/go.md"
  listing_report 400
  assert_output --regexp 'LISTBUDGET +listing +418B'
}

@test "LISTBUDGET: paths: and disable-model-invocation: true are not listed" {
  mkdeployed big "description: $(desc 200)"
  mkdeployed gated "description: $(desc 200)" "paths:" '  - "Assets/**"'
  mkdeployed draft "description: $(desc 200)" "disable-model-invocation: true"
  listing_report 400
  refute_output --partial "LISTBUDGET"
}

@test "LISTBUDGET stays out of --lint, which has no deployed tree" {
  mkskill ops one >/dev/null
  SKILL_LISTING_MAX=1 lint
  assert_success
}

# A parser error quotes the text it choked on; the nightly reads this report as JSON.
@test "--json stays valid when a finding carries quotes" {
  mkdir -p "$HOME/empty/pub/.claude/commands"
  printf -- '---\ndescription: x\nargument-hint: [--a?] [--b?]\n---\n' > "$HOME/empty/pub/.claude/commands/bad.md"
  listing_report 1000 --json
  assert_failure
  echo "$output" | jq -e '.findings[] | select(.type == "BADYAML")'
}
