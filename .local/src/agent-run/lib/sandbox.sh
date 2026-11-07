# shellcheck shell=bash
# sandbox.sh - resolve a lane's SANDBOX_PROFILE into the isolation its harness enforces.
#
# Sourced by agentctl-run. A runner conf sets SANDBOX_PROFILE=<name> (it arrives as
# environment on a supervised runner) to run that lane in the OS sandbox described by
# ~/.config/agentctl/sandbox/<name>.json. The profile is content: the credential paths
# to hide, the paths to keep writable, the hosts to allow. This file is the mechanism and
# the switches no profile may turn off. Unset means the lane runs unsandboxed, as before.
# docs/contract.md "Lane sandbox" has the table.

SANDBOX_DIR="${AGENTCTL_SANDBOX_DIR:-$HOME/.config/agentctl/sandbox}"

# The shape a profile must have before any harness builds flags from it. A list that is not an
# array of strings would break the jq that builds the flags, and a path that is neither absolute
# nor ~/ means different things to the sandbox and to a permission rule.
SANDBOX_SHAPE='
  def strs: . == null or (type == "array" and all(type == "string"));
  def paths: strs and all((. // [])[]; startswith("/") or startswith("~/"));
  type == "object" and (.sandbox | type == "object")
  and ((.permissions // {}) | type == "object") and (.permissions.deny | strs)
  and ((.sandbox.filesystem // {}) | type == "object") and ((.sandbox.network // {}) | type == "object")
  and (.sandbox.filesystem.denyRead | paths) and (.sandbox.filesystem.allowWrite | paths)
  and (.sandbox.filesystem.denyWrite | paths) and (.sandbox.network.allowedDomains | strs)'

# sandbox_load -> SANDBOX_FILE (empty for an unsandboxed lane), and the lane's GitHub token.
# Fails closed like role_load: a named profile that is missing or not JSON refuses the run,
# because running a lane that asked for a sandbox without one is the failure this prevents.
sandbox_load() {
  SANDBOX_FILE=""
  if [ -n "${SANDBOX_PROFILE:-}" ]; then
    [[ "$SANDBOX_PROFILE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || role_die "SANDBOX_PROFILE '$SANDBOX_PROFILE' is not a profile name"
    SANDBOX_FILE="$SANDBOX_DIR/$SANDBOX_PROFILE.json"
    [ -r "$SANDBOX_FILE" ] || role_die "lane sandbox '$SANDBOX_PROFILE' wants $SANDBOX_FILE, which is not readable. Refusing to run unsandboxed."
    jq -e "$SANDBOX_SHAPE" "$SANDBOX_FILE" >/dev/null 2>&1 || role_die "lane sandbox $SANDBOX_FILE is not a valid profile: it needs a sandbox object, every list an array of strings, and every path absolute or ~/. Refusing to run unsandboxed."
  fi
  # GH_TOKEN_FILE: the lane's own repo-scoped token, which the human creates. A sandboxed lane
  # cannot read gh's login (the profile hides it), and must not inherit a broad token from the
  # environment either, so without its own file it gets none.
  if [ -n "${GH_TOKEN_FILE:-}" ]; then
    [ -r "$GH_TOKEN_FILE" ] && [ -s "$GH_TOKEN_FILE" ] || role_die "GH_TOKEN_FILE=$GH_TOKEN_FILE is not a readable, non-empty file"
    GH_TOKEN="$(tr -d '[:space:]' < "$GH_TOKEN_FILE")"
    export GH_TOKEN
    # The lane needs the token itself, not where it is kept.
    unset GITHUB_TOKEN GH_TOKEN_FILE
  elif [ -n "$SANDBOX_FILE" ]; then
    unset GH_TOKEN GITHUB_TOKEN
  fi
}

# sandbox_git_common -> the absolute git common dir of the cwd, or nothing outside a repo. In a
# worktree it lies outside the cwd, and `git commit` writes objects and refs there.
sandbox_git_common() {
  git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

# The oldest claude that honours permissions.blockWritesOutsideWorkingDirectories. An older one
# ignores the key, which would leave Edit and Write unbounded under the bypass a lane runs with.
SANDBOX_CLAUDE_MIN="${SANDBOX_CLAUDE_MIN:-2.1.314}"

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
