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

# The oldest claude that honours permissions.blockWritesOutsideWorkingDirectories. An older one
# ignores the key, which would leave Edit and Write unbounded under the bypass a lane runs with.
SANDBOX_CLAUDE_MIN="${SANDBOX_CLAUDE_MIN:-2.1.314}"

# What claude's sandbox runtime needs on Linux: bwrap to jail the shell, socat to bridge it to the
# proxy that enforces allowedDomains. Checked up front so a missing one is a recorded refusal, not a
# failed call whose reason only claude's stderr carries.
SANDBOX_CLAUDE_NEEDS="${SANDBOX_CLAUDE_NEEDS:-bwrap socat}"

# sandbox_claude_version_ok -> success when the claude on PATH is at least SANDBOX_CLAUDE_MIN.
sandbox_claude_version_ok() {
  local v
  v="$(claude --version 2>/dev/null | grep -oE '^[0-9]+(\.[0-9]+)+' | head -n1)"
  [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$SANDBOX_CLAUDE_MIN" "$v" | sort -V | head -n1)" = "$SANDBOX_CLAUDE_MIN" ]
}

# sandbox_claude_settings -> the --settings JSON for claude: the profile, with the switches that
# make it a hard gate forced on, and the git common dir writable except its hooks and config (code
# and settings every later git run on that repo, sandboxed or not, would pick up). The sandbox
# confines Bash only, so the in-process tools get the same bounds as permission settings: writes
# outside allowWrite and the common dir are refused (blockWritesOutsideWorkingDirectories plus
# additionalDirectories), each denyWrite path is an Edit() deny, each denyRead path a Read() and
# Edit() deny. docs/contract.md "Lane sandbox" has the reasoning. Rule paths: ~/ passes through;
# an absolute path takes the // prefix rules need.
sandbox_claude_settings() {
  jq -c --arg common "$(sandbox_git_common)" --arg home "${HOME%/}" '
    def rulepath: if startswith("/") then "/" + . else . end;
    .sandbox.enabled = true
    | .sandbox.failIfUnavailable = true
    | .sandbox.allowUnsandboxedCommands = false
    | .sandbox.network.strictAllowlist = true
    | .sandbox.filesystem.allowWrite = ((.sandbox.filesystem.allowWrite // []) + (if $common == "" then [] else [$common] end))
    | .sandbox.filesystem.denyWrite = ((.sandbox.filesystem.denyWrite // []) + (if $common == "" then [] else [$common + "/hooks", $common + "/config"] end))
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

# sandbox_codex_flags -> one -c override per line for codex's workspace-write sandbox: the
# profile's allowWrite (~/ expanded) plus the git common dir as writable roots, network off.
sandbox_codex_flags() {
  jq -r --arg common "$(sandbox_git_common)" --arg home "$HOME" '
    "sandbox_workspace_write.writable_roots=\(((.sandbox.filesystem.allowWrite // []) | map(sub("^~/"; $home + "/")))
        + (if $common == "" then [] else [$common] end) | tojson)",
    "sandbox_workspace_write.network_access=false"' \
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
# a writable one would let it move the shared repo's refs. Paths are passed as given; srt expands ~/
# and follows links, so name a stowed file by its target.
sandbox_srt_settings() {
  local ro=() rw=() pkg
  while [ $# -gt 0 ]; do
    case "$1" in
      --ro) ro+=("$2"); shift 2 ;;
      --rw) rw+=("$2"); shift 2 ;;
      *) return 2 ;;
    esac
  done
  pkg=$(realpath -e "$(command -v srt)" 2>/dev/null)
  case "$pkg" in */dist/*) pkg=${pkg%/dist/*} ;; *) pkg="" ;; esac
  jq -c --arg common "$(sandbox_git_common)" --arg pkg "$pkg" \
    --argjson ro "$(printf '%s\n' "${ro[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    --argjson rw "$(printf '%s\n' "${rw[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" '
    (if $common == "" then [] else [$common] end) as $c
    | (.sandbox.filesystem // {}) as $fs
    | {network: ((.sandbox.network // {}) | .allowedDomains //= [] | .deniedDomains //= [] | .strictAllowlist = true),
       filesystem: {
         denyRead: ($fs.denyRead // []),
         allowRead: (["."] + $ro + $rw + $c + ($fs.allowRead // []) + ($fs.allowWrite // []) + (if $pkg == "" then [] else [$pkg] end)),
         allowWrite: (["."] + $rw + ($fs.allowWrite // [])),
         denyWrite: ($fs.denyWrite // [])}}' \
    "$SANDBOX_FILE"
}

# sandbox_env_clear -> `env -i` with each SANDBOX_ENV_KEEP variable, left unexpanded (NAME="${NAME-}")
# for the shell that runs the line (bash or zsh, set -u or not) to fill in from its own environment.
sandbox_env_clear() {
  local v out="env -i"
  for v in $SANDBOX_ENV_KEEP; do out+=" $v=\"\${$v-}\""; done
  printf '%s\n' "$out"
}
