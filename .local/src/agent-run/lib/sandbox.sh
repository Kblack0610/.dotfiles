# shellcheck shell=bash
# sandbox.sh - resolve a lane's SANDBOX_PROFILE into the isolation its harness enforces.
#
# Sourced by agentctl-run, and by fleet-dispatch for a harness that names one (srt, below). A runner conf sets SANDBOX_PROFILE=<name> (it arrives as
# environment on a supervised runner) to run that lane in the OS sandbox described by
# ~/.config/agentctl/sandbox/<name>.json. The profile is content: the credential paths
# to hide, the paths to keep writable, the hosts to allow. This file is the mechanism and
# the switches no profile may turn off. Unset means the lane runs unsandboxed, as before.
# docs/contract.md "Lane sandbox" has the table.

SANDBOX_DIR="${AGENTCTL_SANDBOX_DIR:-$HOME/.config/agentctl/sandbox}"
AGENTCTL_SANDBOX_REFUSALS="${AGENTCTL_SANDBOX_REFUSALS:-${XDG_STATE_HOME:-$HOME/.local/state}/agentctl/sandbox-refusals.jsonl}"

# The shape a profile must have before any harness builds flags from it. A list that is not an
# array of strings would break the jq that builds the flags, and a path that is neither absolute
# nor ~/ means different things to the sandbox and to a permission rule.
SANDBOX_SHAPE='
  def strs: . == null or (type == "array" and all(type == "string"));
  def paths: strs and all((. // [])[]; startswith("/") or startswith("~/"));
  type == "object" and (.sandbox | type == "object")
  and ((.permissions // {}) | type == "object") and (.permissions.deny | strs)
  and ((.sandbox.filesystem // {}) | type == "object") and ((.sandbox.network // {}) | type == "object")
  and (.sandbox.filesystem.denyRead | paths) and (.sandbox.filesystem.allowRead | paths) and (.sandbox.filesystem.allowWrite | paths)
  and (.sandbox.filesystem.denyWrite | paths) and (.sandbox.network.allowedDomains | strs)'

# sandbox_load -> SANDBOX_FILE (empty for an unsandboxed lane), and the lane's GitHub token.
# Fails closed like role_load: a named profile that is missing or not JSON refuses the run,
# because running a lane that asked for a sandbox without one is the failure this prevents.
sandbox_load() {
  SANDBOX_FILE=""
  if [ -n "${SANDBOX_PROFILE:-}" ]; then
    [[ "$SANDBOX_PROFILE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || sandbox_refuse "SANDBOX_PROFILE '$SANDBOX_PROFILE' is not a profile name"
    SANDBOX_FILE="$SANDBOX_DIR/$SANDBOX_PROFILE.json"
    [ -r "$SANDBOX_FILE" ] || sandbox_refuse "lane sandbox '$SANDBOX_PROFILE' wants $SANDBOX_FILE, which is not readable. Refusing to run unsandboxed."
    jq -e "$SANDBOX_SHAPE" "$SANDBOX_FILE" >/dev/null 2>&1 || sandbox_refuse "lane sandbox $SANDBOX_FILE is not a valid profile: it needs a sandbox object, every list an array of strings, and every path absolute or ~/. Refusing to run unsandboxed."
    # The cwd is writable in the sandbox, so a lane started from $HOME or above it (a user unit with
    # no WorkingDirectory starts in $HOME) would have no write bound at all. Physical paths, so a
    # symlinked $HOME cannot slip past.
    local here home
    here="$(pwd -P)"; home="$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"
    case "${home%/}/" in "${here%/}/"*) sandbox_refuse "lane sandbox '$SANDBOX_PROFILE' would run from $here, which holds all of \$HOME, and the cwd is writable. Start the lane from its own directory (its inbox or a worktree)." ;; esac
  fi
  # GH_TOKEN_FILE: the lane's own repo-scoped token, which the human creates. A sandboxed lane
  # cannot read gh's login (the profile hides it), and must not inherit a broad token from the
  # environment either, so without its own file it gets none.
  if [ -n "${GH_TOKEN_FILE:-}" ]; then
    [ -r "$GH_TOKEN_FILE" ] && [ -s "$GH_TOKEN_FILE" ] || sandbox_refuse "GH_TOKEN_FILE=$GH_TOKEN_FILE is not a readable, non-empty file"
    GH_TOKEN="$(tr -d '[:space:]' < "$GH_TOKEN_FILE")"
    export GH_TOKEN
    # The lane needs the token itself, not where it is kept.
    unset GITHUB_TOKEN GH_TOKEN_FILE
  elif [ -n "$SANDBOX_FILE" ]; then
    unset GH_TOKEN GITHUB_TOKEN
  fi
}

# sandbox_refuse <why>: refuse the run (role_die, exit 78), first appending a line for a named call
# to AGENTCTL_SANDBOX_REFUSALS: {agent, role, harness, sandbox, at, why}. The lane-sandbox-refusals
# watch reads it. It is not calls.jsonl, because every reader of that file counts a line as a call
# made. A name comes from lib/calls.sh, which fleet-dispatch does not load, so there it only refuses.
sandbox_refuse() {
  local name=""
  declare -F calls_name >/dev/null && name="$(calls_name)"
  if [ -n "$name" ]; then
    mkdir -p "$(dirname "$AGENTCTL_SANDBOX_REFUSALS")" 2>/dev/null
    jq -cn --arg agent "$name" --arg role "${ROLE_NAME:-}" --arg harness "${harness:-}" --arg sandbox "${SANDBOX_PROFILE:-}" \
      --arg at "$(date -Iseconds)" --arg why "$1" '
      {agent: $agent, role: $role, harness: $harness, sandbox: $sandbox, at: $at, why: $why}
      | with_entries(select(.value != ""))' | flock "$AGENTCTL_SANDBOX_REFUSALS" tee -a "$AGENTCTL_SANDBOX_REFUSALS" >/dev/null || true
  fi
  role_die "$1"
}

# sandbox_git_common -> the absolute git common dir of the cwd, or nothing outside a repo. In a
# worktree it lies outside the cwd, and `git commit` writes objects and refs there.
sandbox_git_common() {
  git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

# sandbox_git_own -> the absolute git dir of the cwd (from a linked worktree, worktrees/<name> under
# the common dir), or nothing outside a repo.
sandbox_git_own() {
  git rev-parse --path-format=absolute --git-dir 2>/dev/null || true
}

# sandbox_git_linked <common> <own> -> success when the cwd is a linked worktree: its git dir is not
# the common dir.
sandbox_git_linked() {
  [ -n "$2" ] && ! [ "$2" -ef "$1" ]
}

# sandbox_git_writes <common> <own> -> one path per line, nothing outside a repo: the git paths a lane
# may write. From a linked worktree, its own git dir (index, HEAD, its reflog) and the common dir's
# objects, refs, logs and lfs, which commit, fetch, push and git-lfs write; the rest of the common
# dir stays read-only, worktrees/ with it, so a worktree another lane adds after this one starts is
# never writable (a deny list could not name it: srt takes concrete paths only). From a plain clone,
# the git dir is the common dir, whole. srt skips a write path that does not exist yet.
sandbox_git_writes() {
  local common="$1" own="$2"
  [ -n "$common" ] || return 0
  if sandbox_git_linked "$common" "$own"; then
    printf '%s\n' "$own" "$common/objects" "$common/refs" "$common/logs" "$common/lfs"
  else
    printf '%s\n' "$common"
  fi
}

# sandbox_git_denies <common> <own> -> one path per line, nothing outside a repo: what would run code
# or point git elsewhere on a later git run, sandboxed or not. The common dir's hooks, config,
# config.worktree (read once extensions.worktreeConfig is on) and info (info/attributes picks filter,
# diff and merge drivers): outside sandbox_git_writes from a worktree, but denied anyway, in case the
# profile's allowWrite reaches them. From a linked worktree, its own git dir's config.worktree, hooks
# and commondir, and the checkout's .git file. From a plain clone, worktrees/ whole, made first when
# missing (so this creates an empty .git/worktrees): srt denies a missing path with a placeholder
# file, which would break a `git worktree add` run outside while the lane runs, so one mkdir cannot
# make is left off. Any other missing path is denied too, so the lane cannot create it.
sandbox_git_denies() {
  local common="$1" own="$2" top
  [ -n "$common" ] || return 0
  printf '%s\n' "$common/hooks" "$common/config" "$common/config.worktree" "$common/info"
  if sandbox_git_linked "$common" "$own"; then
    printf '%s\n' "$own/config.worktree" "$own/hooks" "$own/commondir"
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] && [ -f "$top/.git" ] && printf '%s\n' "$top/.git"
  else
    mkdir -p "$common/worktrees" 2>/dev/null && printf '%s\n' "$common/worktrees"
  fi
  return 0
}

# The oldest claude that honours permissions.blockWritesOutsideWorkingDirectories. An older one
# ignores the key, which would leave Edit and Write unbounded under the bypass a lane runs with.
SANDBOX_CLAUDE_MIN="${SANDBOX_CLAUDE_MIN:-2.1.314}"

# What claude's sandbox runtime needs on Linux: bwrap to jail the shell, socat to bridge it to the
# proxy that enforces allowedDomains. Checked up front so a missing one is a recorded refusal, not a
# failed call whose reason only claude's stderr carries.
SANDBOX_CLAUDE_NEEDS="${SANDBOX_CLAUDE_NEEDS:-bwrap socat}"

# sandbox_version_at_least <min> <cmd...> -> success when the first version number `<cmd> --version`
# prints is at least <min>.
sandbox_version_at_least() {
  local min="$1" v; shift
  v="$("$@" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | awk 'NR==1')"
  [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$min" "$v" | sort -V | awk 'NR==1')" = "$min" ]
}

# sandbox_claude_version_ok -> success when the claude on PATH is at least SANDBOX_CLAUDE_MIN.
sandbox_claude_version_ok() { sandbox_version_at_least "$SANDBOX_CLAUDE_MIN" claude; }

# sandbox_claude_settings -> the --settings JSON for claude: the profile, with the switches that
# make it a hard gate forced on, and sandbox_git_writes writable except sandbox_git_denies. The sandbox
# confines Bash only, so the in-process tools get the same bounds as permission settings: writes
# outside allowWrite (git paths included) are refused (blockWritesOutsideWorkingDirectories plus
# additionalDirectories), each denyWrite path is an Edit() deny, each denyRead path a Read() and
# Edit() deny. docs/contract.md "Lane sandbox" has the reasoning. Rule paths: ~/ passes through;
# an absolute path takes the // prefix rules need.
sandbox_claude_settings() {
  local common own
  common="$(sandbox_git_common)"; own="$(sandbox_git_own)"
  jq -c --arg home "${HOME%/}" \
    --argjson gitwrite "$(sandbox_git_writes "$common" "$own" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --argjson gitdeny "$(sandbox_git_denies "$common" "$own" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
    def rulepath: if startswith("/") then "/" + . else . end;
    .sandbox.enabled = true
    | .sandbox.failIfUnavailable = true
    | .sandbox.allowUnsandboxedCommands = false
    | .sandbox.network.strictAllowlist = true
    | .sandbox.filesystem.allowWrite = ((.sandbox.filesystem.allowWrite // []) + $gitwrite)
    | .sandbox.filesystem.denyWrite = ((.sandbox.filesystem.denyWrite // []) + $gitdeny)
    | .permissions.blockWritesOutsideWorkingDirectories = true
    | .permissions.additionalDirectories = [.sandbox.filesystem.allowWrite[] | sub("^~/"; $home + "/")]
    | .permissions.deny = ((.permissions.deny // [])
        + [(.sandbox.filesystem.denyRead // [])[] | rulepath | "Read(\(.))", "Read(\(.)/**)", "Edit(\(.))", "Edit(\(.)/**)"]
        + [.sandbox.filesystem.denyWrite[] | rulepath | "Edit(\(.))", "Edit(\(.)/**)"])' \
    "$SANDBOX_FILE"
}

# sandbox_codex_refusal -> why codex cannot enforce this profile, or nothing. Codex has no read
# denial and no per-host allowlist, so a profile that hides paths or lists hosts is refused there.
sandbox_codex_refusal() {
  jq -r 'if ((.sandbox.filesystem.denyRead // []) | length) > 0 then "it hides paths (denyRead), and codex has no read denial"
    elif ((.sandbox.network.allowedDomains // []) | length) > 0 then "it lists hosts (allowedDomains), and codex network is all or nothing"
    else empty end' "$SANDBOX_FILE"
}

# The codex permission profile a sandboxed lane runs under, defined on the command line only.
SANDBOX_CODEX_PERMS="agentctl-lane"

# The oldest codex this profile was proven on (codex sandbox, 2026-11-16). One that predates
# permission profiles would ignore default_permissions and run on ~/.codex/config.toml's sandbox.
SANDBOX_CODEX_MIN="${SANDBOX_CODEX_MIN:-0.168.0}"

# sandbox_codex_flags -> one -c override per line: a codex permission profile (default_permissions
# and its [permissions] table, in place of --sandbox, which codex refuses beside them) that extends
# :workspace (cwd and the tmp dirs writable, the rest readable) with the profile's allowWrite (~/
# expanded) and sandbox_git_writes writable, and sandbox_git_denies and the profile's denyWrite
# read-only, network off. A narrower entry wins; on the same path codex lets write beat read, so
# paths lose a trailing / and jq keeps the last of a repeated key, putting the deny last. Keys and
# values are JSON strings, whose escapes TOML basic strings share. Bubblewrap enforces it on Linux;
# the legacy writable_roots could not deny a path under a root, so the common dir's hooks and config
# were writable.
sandbox_codex_flags() {
  local common own
  common="$(sandbox_git_common)"; own="$(sandbox_git_own)"
  jq -r --arg home "${HOME%/}" --arg name "$SANDBOX_CODEX_PERMS" \
    --argjson gitwrite "$(sandbox_git_writes "$common" "$own" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --argjson gitdeny "$(sandbox_git_denies "$common" "$own" | jq -Rsc 'split("\n") | map(select(. != ""))')" '
    def abs: sub("^~/"; $home + "/") | sub("(?<p>.)/+$"; .p);
    ([(.sandbox.filesystem.allowWrite // []) + $gitwrite | map(abs) | .[] | {key: ., value: "write"}]
      + [$gitdeny + (.sandbox.filesystem.denyWrite // []) | map(abs) | .[] | {key: ., value: "read"}]
      | from_entries) as $fs
    | "default_permissions=\($name | tojson)",
      "permissions={\($name | tojson)={extends=\":workspace\", network={enabled=false}, filesystem={\(
        $fs | to_entries | map("\(.key | tojson)=\(.value | tojson)") | join(", "))}}}"' \
    "$SANDBOX_FILE"
}

# --- srt: a lane whose harness has no sandbox of its own (opencode) runs inside srt, the runtime ---
# claude's sandbox is built on (@anthropic-ai/sandbox-runtime: bwrap, its own network namespace, and a
# proxy that holds the run to allowedDomains), so one profile means the same thing on both.

# What an srt-held run needs on PATH: srt itself, and on Linux the bwrap and socat it drives (macOS
# srt uses sandbox-exec).
if [ "$(uname -s)" = Linux ]; then SANDBOX_SRT_NEEDS="${SANDBOX_SRT_NEEDS:-srt bwrap socat}"; else SANDBOX_SRT_NEEDS="${SANDBOX_SRT_NEEDS:-srt}"; fi

# The environment an srt-held run keeps from its pane; every other variable (the gateway master key,
# tokens, the tmux and D-Bus sockets) is dropped. srt adds its own proxy variables. Each reads as
# empty when the pane has none, which these treat as unset (TZ would not, so it is not kept).
SANDBOX_ENV_KEEP="HOME USER LOGNAME SHELL PATH LANG LC_ALL TERM COLORTERM"

# sandbox_srt_refusal -> why srt cannot hold a run here, or nothing: a SANDBOX_SRT_NEEDS tool missing.
sandbox_srt_refusal() {
  local t
  for t in $SANDBOX_SRT_NEEDS; do
    command -v "$t" >/dev/null 2>&1 || { echo "$t is not on PATH"; return; }
  done
}

# sandbox_srt_settings [--ro <path>] [--rw <path>]... -> the srt --settings JSON: the profile's
# filesystem and network, with the run's cwd (".", srt resolves it where it starts) and each --rw path
# writable, and each --ro path, the profile's allowRead, the git common dir and srt's own package (its
# seccomp helper runs inside) readable through denyRead, and strictAllowlist on. The common dir is
# read-only: the run's commits are not needed (fleet-dispatch moves and scores its tree outside), and
# a writable one would let it move the shared repo's refs. The checkout's .git (a linked worktree's
# file pointing at its git dir, or a plain clone's git dir) sits in the writable cwd, so it is denied:
# fleet-dispatch runs git in that tree outside the sandbox. Paths are passed as given; srt expands ~/ and follows links, so name a stowed
# file by its target.
sandbox_srt_settings() {
  local ro=() rw=() pkg dotgit
  while [ $# -gt 0 ]; do
    case "$1" in
      --ro) ro+=("$2"); shift 2 ;;
      --rw) rw+=("$2"); shift 2 ;;
      *) return 2 ;;
    esac
  done
  pkg=$(realpath -e "$(command -v srt)" 2>/dev/null || true)
  case "$pkg" in */dist/*) pkg=${pkg%/dist/*} ;; *) pkg="" ;; esac
  dotgit="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$dotgit" ] && [ -e "$dotgit/.git" ] && dotgit="$dotgit/.git" || dotgit=""
  jq -c --arg common "$(sandbox_git_common)" --arg pkg "$pkg" --arg dotgit "$dotgit" \
    --argjson ro "$(printf '%s\n' "${ro[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    --argjson rw "$(printf '%s\n' "${rw[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" '
    (if $common == "" then [] else [$common] end) as $c
    | (.sandbox.filesystem // {}) as $fs
    | {network: ((.sandbox.network // {}) | .allowedDomains //= [] | .deniedDomains //= [] | .strictAllowlist = true),
       filesystem: {
         denyRead: ($fs.denyRead // []),
         allowRead: (["."] + $ro + $rw + $c + ($fs.allowRead // []) + ($fs.allowWrite // []) + (if $pkg == "" then [] else [$pkg] end)),
         allowWrite: (["."] + $rw + ($fs.allowWrite // [])),
         denyWrite: (($fs.denyWrite // []) + (if $dotgit == "" then [] else [$dotgit] end))}}' \
    "$SANDBOX_FILE"
}

# sandbox_env_clear -> `env -i` with each SANDBOX_ENV_KEEP variable, left unexpanded (NAME="${NAME-}")
# for the shell that runs the line (bash or zsh, set -u or not) to fill in from its own environment.
sandbox_env_clear() {
  local v out="env -i"
  for v in $SANDBOX_ENV_KEEP; do out+=" $v=\"\${$v-}\""; done
  printf '%s\n' "$out"
}
