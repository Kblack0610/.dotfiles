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

# sandbox_load -> SANDBOX_FILE (empty for an unsandboxed lane), and the lane's GitHub token.
# Fails closed like role_load: a named profile that is missing or not JSON refuses the run,
# because running a lane that asked for a sandbox without one is the failure this prevents.
sandbox_load() {
  SANDBOX_FILE=""
  if [ -n "${SANDBOX_PROFILE:-}" ]; then
    [[ "$SANDBOX_PROFILE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || role_die "SANDBOX_PROFILE '$SANDBOX_PROFILE' is not a profile name"
    SANDBOX_FILE="$SANDBOX_DIR/$SANDBOX_PROFILE.json"
    jq -e 'type == "object"' "$SANDBOX_FILE" >/dev/null 2>&1 || role_die "lane sandbox '$SANDBOX_PROFILE' wants $SANDBOX_FILE, which is not a readable JSON object. Refusing to run unsandboxed."
  fi
  # GH_TOKEN_FILE: the lane's own repo-scoped token, which the human creates. A sandboxed lane
  # cannot read gh's login (the profile hides it), and must not inherit a broad token from the
  # environment either, so without its own file it gets none.
  if [ -n "${GH_TOKEN_FILE:-}" ]; then
    [ -r "$GH_TOKEN_FILE" ] && [ -s "$GH_TOKEN_FILE" ] || role_die "GH_TOKEN_FILE=$GH_TOKEN_FILE is not a readable, non-empty file"
    GH_TOKEN="$(tr -d '[:space:]' < "$GH_TOKEN_FILE")"
    export GH_TOKEN
    unset GITHUB_TOKEN
  elif [ -n "$SANDBOX_FILE" ]; then
    unset GH_TOKEN GITHUB_TOKEN
  fi
}

# sandbox_git_common -> the absolute git common dir of the cwd, or nothing outside a repo. In a
# worktree it lies outside the cwd, and `git commit` writes objects and refs there.
sandbox_git_common() {
  git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

# sandbox_claude_settings -> the --settings JSON for claude: the profile, with the switches that
# make it a hard gate forced on, the git common dir writable, and each denyRead path a Read()
# deny rule too, because the sandbox confines Bash only and the Read tool runs in-process.
# Rule paths: ~ and relative pass through; an absolute path takes the // prefix rules need.
sandbox_claude_settings() {
  jq -c --arg common "$(sandbox_git_common)" '
    .sandbox.enabled = true
    | .sandbox.failIfUnavailable = true
    | .sandbox.allowUnsandboxedCommands = false
    | .sandbox.network.strictAllowlist = true
    | .sandbox.filesystem.allowWrite = ((.sandbox.filesystem.allowWrite // []) + (if $common == "" then [] else [$common] end))
    | .permissions.deny = ((.permissions.deny // [])
        + [(.sandbox.filesystem.denyRead // [])[] | (if startswith("/") then "/" + . else . end) | "Read(\(.))", "Read(\(.)/**)"])' \
    "$SANDBOX_FILE"
}

# sandbox_codex_flags -> one -c override per line for codex's workspace-write sandbox: the
# profile's allowWrite (~ expanded) plus the git common dir as writable roots, and network on
# when the profile allows any host. Codex has no per-host allowlist and no read denial, so on
# codex a profile confines writes only (docs/contract.md says so).
sandbox_codex_flags() {
  jq -r --arg common "$(sandbox_git_common)" --arg home "$HOME" '
    "sandbox_workspace_write.writable_roots=\(((.sandbox.filesystem.allowWrite // []) | map(sub("^~"; $home)))
        + (if $common == "" then [] else [$common] end) | tojson)",
    "sandbox_workspace_write.network_access=\((.sandbox.network.allowedDomains // []) | length > 0)"' \
    "$SANDBOX_FILE"
}
