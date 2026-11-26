#!/bin/bash
set -euo pipefail

DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"
# rulesync source lives in the private overlay (~/.dotfiles-private), deployed at
# ~/.config/rulesync-global. Absent on public-only machines (handled below).
RULESYNC_ROOT="${RULESYNC_ROOT:-$HOME/.config/rulesync-global}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
OPENCODE_HOME="${OPENCODE_HOME:-$HOME/.config/opencode}"
RULESYNC_BIN="${RULESYNC_BIN:-}"
RULES_CLAUDE_MD="${RULES_CLAUDE_MD:-$CLAUDE_HOME/CLAUDE.md}"
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
CODEX_OWNED_TOML="${CODEX_OWNED_TOML:-$SCRIPT_DIR/config.owned.toml}"

START_MARKER="# >>> dotfiles codex managed start >>>"
END_MARKER="# <<< dotfiles codex managed end <<<"
# Top-level keys must precede every table, so the owned keys get their own region at the head.
HEAD_START="# >>> dotfiles codex owned keys start >>>"
HEAD_END="# <<< dotfiles codex owned keys end <<<"

find_rulesync() {
    if [ -n "$RULESYNC_BIN" ] && [ -x "$RULESYNC_BIN" ]; then
        printf '%s\n' "$RULESYNC_BIN"
        return 0
    fi

    if command -v rulesync >/dev/null 2>&1; then
        command -v rulesync
        return 0
    fi

    if [ -x "$HOME/.rulesync/bin/rulesync" ]; then
        printf '%s\n' "$HOME/.rulesync/bin/rulesync"
        return 0
    fi

    return 1
}

RULESYNC="$(find_rulesync || true)"
if [ -z "$RULESYNC" ]; then
    echo "rulesync is required. Install it first:" >&2
    echo "  curl -fsSL https://github.com/dyoshikawa/rulesync/releases/latest/download/install.sh | bash" >&2
    exit 1
fi

if [ ! -d "$RULESYNC_ROOT" ]; then
    # Public-only machine (no private overlay) — nothing to sync; skip cleanly.
    echo "rulesync source ($RULESYNC_ROOT) absent — skipping AI-config sync." >&2
    exit 0
fi

stage_dir="$(mktemp -d)"
codex_tmp="$(mktemp)"
managed_tmp="$(mktemp)"
features_tmp="$(mktemp)"
trap 'rm -rf "$stage_dir"; rm -f "$codex_tmp" "$managed_tmp" "$features_tmp"' EXIT

# -L dereferences. On a --no-folding stow layout every file under $RULESYNC_ROOT is a
# RELATIVE symlink into the private overlay (../../../../.dotfiles-private/...), and a plain
# `cp -R` copies the link verbatim — so it dangles the moment it lands in $stage_dir and
# rulesync reads an empty tree. It failed silently this way: the generate step still emitted
# the files the required-file check below looks for, so the sync exited 0 having synced nothing.
cp -RL "$RULESYNC_ROOT"/. "$stage_dir"/

# rulesync exits 0 even when it cannot read its own inputs, so the staged tree is the only
# place a broken source is still detectable. Assert the canonical rule file survived the copy.
if [ ! -s "$stage_dir/.rulesync/rules/overview.md" ]; then
    echo "Staged rulesync tree is missing or empty: .rulesync/rules/overview.md" >&2
    echo "  (source: $RULESYNC_ROOT — check for dangling symlinks)" >&2
    exit 1
fi

# The shared sections live only in the global CLAUDE.md: overview.md names them with markers.
python3 "$SCRIPT_DIR/splice-shared-rules.py" "$stage_dir/.rulesync/rules/overview.md" "$RULES_CLAUDE_MD"

(
    cd "$stage_dir"
    "$RULESYNC" generate --targets codexcli,geminicli,opencode --features rules,mcp >/dev/null
)

for required_file in \
    "$stage_dir/AGENTS.md" \
    "$stage_dir/.codex/config.toml" \
    "$stage_dir/opencode.jsonc"; do
    if [ ! -f "$required_file" ]; then
        echo "Missing expected Rulesync output: $required_file" >&2
        exit 1
    fi
done

# Gemini is OPTIONAL, unlike the three above: rulesync 11.x reports geminicli as not
# supporting the rules/mcp features and emits nothing for it, which made this script
# exit 1 and sync NOTHING for codex or opencode either. Detect instead of require, and
# leave $GEMINI_HOME untouched when there is no staged file — a merge against an absent
# stage would write an empty mcpServers over the live one.
gemini_rules=0; [ -f "$stage_dir/GEMINI.md" ] && gemini_rules=1
gemini_mcp=0;   [ -f "$stage_dir/.gemini/settings.json" ] && gemini_mcp=1
if [ "$gemini_rules" = 0 ] || [ "$gemini_mcp" = 0 ]; then
    echo "note: rulesync emitted no Gemini output; leaving $GEMINI_HOME untouched" >&2
fi

mkdir -p "$CODEX_HOME" "$GEMINI_HOME" "$OPENCODE_HOME"

# Claude Code's CLAUDE.md is stow-managed from ~/.dotfiles-private/.claude/ and MCP servers live in each
# repo's .mcp.json - do NOT write them here; it would clobber the stow symlinks.
cp "$stage_dir/AGENTS.md" "$CODEX_HOME/AGENTS.md"
if [ "$gemini_rules" = 1 ]; then
    cp "$stage_dir/GEMINI.md" "$GEMINI_HOME/GEMINI.md"
fi
cp "$stage_dir/AGENTS.md" "$OPENCODE_HOME/AGENTS.md"

# agy (Google's Antigravity CLI) has no rulesync target and reads neither ~/.gemini/GEMINI.md nor
# ~/.claude: its global customization root is ~/.gemini/config/ (rules/*.md, skills.json). The
# rules are the same staged AGENTS.md Codex and opencode get; the skills are one declared path to
# the Claude corpus, so a skill added or removed there needs no sync. Other skills.json entries
# (the human's own) stay.
AGY_CONFIG_DIR="$GEMINI_HOME/config"
mkdir -p "$AGY_CONFIG_DIR/rules"
{ printf -- '---\ntrigger: always_on\n---\n\n'; cat "$stage_dir/AGENTS.md"; } > "$AGY_CONFIG_DIR/rules/fleet.md"
python3 - "$AGY_CONFIG_DIR/skills.json" "$CLAUDE_HOME/skills" <<'PY'
import json, os, sys
path, corpus = sys.argv[1], sys.argv[2]
try:
    cur = json.load(open(path)) if os.path.getsize(path) else {}
except FileNotFoundError:
    cur = {}
except ValueError as e:
    sys.exit(f"agy: {path} is not JSON ({e}); left as it is, fix it by hand")
if not isinstance(cur, dict) or not isinstance(cur.get("entries", []), list):
    sys.exit(f"agy: {path} has no entries list; left as it is, fix it by hand")
keep = [e for e in cur.get("entries", []) if not (isinstance(e, dict) and e.get("path") == corpus)]
cur["entries"] = keep + [{"path": corpus}]
with open(path + ".tmp", "w") as f:
    json.dump(cur, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PY

# agy hand sessions have no guard hook, and a fleet run's srt jail does not cover `agy` started by hand,
# so the destructive Bash denies Claude keeps in settings.json are mirrored into agy's own
# `permissions.deny` (ar-4967): one `command(<binary and subcommand>)` per whole-word prefix, plus the
# credential files an agent must not read or write. agy's rules are prefixes with no globs, so an entry
# with a glob in the middle or a shell metacharacter is skipped, as sync-codex-home.sh's deny_rules does.
# The key is the one agy's settings struct declares (permissions.allow, .deny, .ask), read from the
# binary 2026-11-25, not yet exercised by a live deny. A rule the human added by hand stays: the sync adds to the list. The hook form (hooks.json) is a follow-up.
AGY_SETTINGS="${AGY_SETTINGS:-$GEMINI_HOME/antigravity-cli/settings.json}"
AGY_DENY_COUNT=$(python3 - "$AGY_SETTINGS" "$CLAUDE_HOME/settings.json" "$HOME" <<'PY'
import json, os, re, sys
path, claude, home = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    deny = json.load(open(claude)).get("permissions", {}).get("deny", [])
except (FileNotFoundError, ValueError):
    deny = []
rules = set()
for entry in deny:
    m = re.fullmatch(r"Bash\((.*)\)", entry) if isinstance(entry, str) else None
    if not m:
        continue
    pat = re.sub(r"[ ]?\*$", "", m.group(1)).strip()
    if not pat or re.search(r"[*|<>$~;&`\"'()]", pat):
        continue
    rules.add("command(" + " ".join(pat.split()) + ")")
claude_home = os.path.dirname(claude)
for cred in (os.path.join(home, ".ssh"), os.path.join(home, ".config/gh"), os.path.join(claude_home, ".credentials.json"),
             os.path.join(home, ".claude/.credentials.json"), os.path.join(home, ".codex/auth.json")):
    for kind in ("read_file", "write_file"):
        rules.add(f"{kind}({cred})")
try:
    cur = json.load(open(path)) if os.path.getsize(path) else {}
except FileNotFoundError:
    cur = {}
except ValueError as e:
    sys.exit(f"agy: {path} is not JSON ({e}); left as it is, fix it by hand")
if not isinstance(cur, dict) or not isinstance(cur.get("permissions") or {}, dict):
    sys.exit(f"agy: {path} has no permissions object; left as it is, fix it by hand")
perms = cur.get("permissions") or {}
have = [r for r in perms.get("deny", []) if isinstance(r, str)] if isinstance(perms.get("deny", []), list) else []
perms["deny"] = sorted(rules | set(have))
cur["permissions"] = perms
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(cur, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
print(len(perms["deny"]))
PY
) || AGY_DENY_COUNT="not written"

{
    echo "$START_MARKER"
    # rulesync writes each server's `type` and `description`, which Codex does not know: it lists
    # them as "unrecognized configuration settings" at the start of every run.
    awk '/^\[/ { in_server = ($0 ~ /^\[mcp_servers\.[^.]+\]$/) }
         in_server && /^(type|description)[[:space:]]*=/ { next }
         { print }' "$stage_dir/.codex/config.toml"
    # Unset, Codex sends its built-in usage metrics to OpenAI's Statsig
    # (codex-rs core/src/config/otel.rs defaults metrics_exporter to Statsig).
    printf '\n[analytics]\nenabled = false\n'
    echo "$END_MARKER"
} > "$managed_tmp"

# An owned file with no keys matches nothing. A dropped key whose array value runs past its line
# (`key = [` up to a line holding `]`) takes its continuation lines with it.
owned_keys=$(grep -oE '^[A-Za-z0-9_-]+[[:space:]]*=' "$CODEX_OWNED_TOML" | tr -d ' =' | paste -sd'|' || true)
owned_re='^$.'
[ -z "$owned_keys" ] || owned_re="^(${owned_keys})[[:space:]]*="
if [ -f "$CODEX_HOME/config.toml" ]; then
    awk -v start="$START_MARKER" -v end="$END_MARKER" -v hstart="$HEAD_START" -v hend="$HEAD_END" -v owned="$owned_re" '
        $0 == start || $0 == hstart {skip_managed=1; next}
        $0 == end || $0 == hend {skip_managed=0; next}
        in_array { if ($0 ~ /]/) in_array=0; next }
        /^\[/ {in_table=1; skip_owned=($0 ~ /^\[(mcp_servers(\.|])|analytics])/) ? 1 : 0}
        !in_table && skip_managed != 1 && $0 ~ owned { v=$0; sub(/^[^=]*=[[:space:]]*/, "", v); if (v ~ /^\[/ && v !~ /]/) in_array=1; next }
        skip_managed != 1 && skip_owned != 1 {print}
    ' "$CODEX_HOME/config.toml" > "$codex_tmp"
else
    : > "$codex_tmp"
fi

# Keys Codex no longer knows, which earlier syncs wrote: rmcp_client (now built in) and
# codex_hooks (now the stable `hooks` feature). Dropped from [features] so the file holds no
# dead key; the rest of [features] is the human's and stays.
awk '
    /^\[/ { in_features = ($0 == "[features]") }
    in_features && /^(rmcp_client|codex_hooks)[[:space:]]*=/ { next }
    { print }
' "$codex_tmp" > "$features_tmp"
mv "$features_tmp" "$codex_tmp"

awk '
    BEGIN { last_nonblank = 0 }
    {
        lines[NR] = $0
        if ($0 !~ /^[[:space:]]*$/) {
            last_nonblank = NR
        }
    }
    END {
        for (i = 1; i <= last_nonblank; i++) {
            print lines[i]
        }
    }
' "$codex_tmp" > "$features_tmp"
mv "$features_tmp" "$codex_tmp"

if [ -s "$codex_tmp" ]; then
    printf "\n" >> "$codex_tmp"
fi
cat "$managed_tmp" >> "$codex_tmp"
{
    echo "$HEAD_START"
    grep -E '^[A-Za-z0-9_-]+[[:space:]]*=' "$CODEX_OWNED_TOML" || true
    echo "$HEAD_END"
    echo
    sed '/./,$!d' "$codex_tmp"
} > "$features_tmp"
mv "$features_tmp" "$CODEX_HOME/config.toml"

# Codex's skills and hooks.json, from the Claude skill corpus and .config/codex/hooks.json.
"$SCRIPT_DIR/sync-codex-home.sh"

export GEMINI_SETTINGS_PATH="$GEMINI_HOME/settings.json"
export GEMINI_STAGE_PATH="$stage_dir/.gemini/settings.json"
export AGY_MCP_PATH="${AGY_MCP_PATH:-$GEMINI_HOME/config/mcp_config.json}"
export AGY_STAGE_PATH="$stage_dir/.rulesync/mcp.json"
export OPENCODE_CONFIG_PATH="$OPENCODE_HOME/opencode.json"
export OPENCODE_STAGE_PATH="$stage_dir/opencode.jsonc"

python3 <<'PY'
import json
import os
import sys
from pathlib import Path


def read_json(path_str: str) -> dict:
    path = Path(path_str)
    if not path.exists():
        return {}
    text = path.read_text().strip()
    if not text:
        return {}
    return json.loads(text)


def write_json(path_str: str, data: dict) -> None:
    path = Path(path_str)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


gemini_path = os.environ["GEMINI_SETTINGS_PATH"]
gemini_stage_path = os.environ["GEMINI_STAGE_PATH"]
# read_json returns {} for an absent stage file, so merging unconditionally would
# blank the live mcpServers rather than leave it alone.
if Path(gemini_stage_path).exists():
    gemini_current = read_json(gemini_path)
    gemini_stage = read_json(gemini_stage_path)
    gemini_current["mcpServers"] = gemini_stage.get("mcpServers", {})
    write_json(gemini_path, gemini_current)


def agy_server(server: dict) -> dict | None:
    # agy's own shape, as `agy mcp add` writes it: an http server is serverUrl and headers, a
    # stdio one command, args and env, and each carries `disabled`. None: a server it cannot run.
    out = {"disabled": bool(server.get("disabled", False))}
    url = server.get("url") or server.get("httpUrl")
    if url:
        out["serverUrl"] = url
        if server.get("headers"):
            out["headers"] = server["headers"]
        return out
    if not server.get("command"):
        return None
    out["command"] = server["command"]
    for key in ("args", "env"):
        if server.get(key):
            out[key] = server[key]
    return out


# agy has no rulesync target, so its servers come from the rulesync source itself (its rules and
# skills are written above). A server the human added there (`agy mcp add`, unityMCP) stays: the names this
# sync wrote last time sit in <file>.managed, so only a server dropped from the shared set goes.
agy_path = Path(os.environ["AGY_MCP_PATH"])
agy_stage_path = os.environ["AGY_STAGE_PATH"]
if Path(agy_stage_path).exists():
    managed_path = agy_path.with_suffix(".managed")
    shared = read_json(agy_stage_path).get("mcpServers", {})
    was = set(managed_path.read_text().split()) if managed_path.exists() else set()
    agy_current = read_json(str(agy_path))
    servers = {n: s for n, s in agy_current.get("mcpServers", {}).items() if n not in was | set(shared)}
    for name, server in shared.items():
        if (converted := agy_server(server)) is None:
            print(f"note: MCP server {name} has no url or command; left out of {agy_path}", file=sys.stderr)
        else:
            servers[name] = converted
    agy_current["mcpServers"] = servers
    write_json(str(agy_path), agy_current)
    managed_path.write_text("".join(n + "\n" for n in sorted(shared)))

opencode_path = os.environ["OPENCODE_CONFIG_PATH"]
opencode_stage_path = os.environ["OPENCODE_STAGE_PATH"]
opencode_current = read_json(opencode_path)
opencode_stage = read_json(opencode_stage_path)


def opencode_v2_mcp(v1: dict) -> dict:
    # rulesync emits opencode's V1 map ({name: {..., enabled, timeout: ms}}); opencode 2.x
    # reads mcp.servers with `disabled` and a per-phase timeout object.
    if "servers" in v1:  # rulesync already emits the 2.x shape
        return v1
    servers = {}
    for name, server in v1.items():
        server = dict(server)
        if "enabled" in server:
            server["disabled"] = not server.pop("enabled")
        timeout = server.get("timeout")
        if isinstance(timeout, (int, float)) and not isinstance(timeout, bool):
            server["timeout"] = {"execution": server["timeout"]}
        servers[name] = server
    return {"servers": servers}


# opencode.jsonc is a required rulesync output (asserted above), so the stage is never
# absent here; replacing the block prunes a removed server, as the Gemini branch does.
opencode_current["mcp"] = opencode_v2_mcp(opencode_stage.get("mcp", {}))
write_json(opencode_path, opencode_current)
PY

echo "Synced shared AI rules and MCP config (Claude owned by stow, not this script)"
echo "  Codex:  $CODEX_HOME/AGENTS.md and $CODEX_HOME/config.toml"
if [ "$gemini_rules" = 1 ] || [ "$gemini_mcp" = 1 ]; then
    echo "  Gemini: $GEMINI_HOME/GEMINI.md and $GEMINI_HOME/settings.json"
else
    echo "  Gemini: skipped (rulesync target 'geminicli' emitted nothing)"
fi
echo "  agy:    $AGY_CONFIG_DIR/rules/fleet.md, $AGY_CONFIG_DIR/skills.json, $AGY_MCP_PATH and $AGY_SETTINGS ($AGY_DENY_COUNT deny rules)"
echo "  OpenCode: $OPENCODE_HOME/AGENTS.md and $OPENCODE_HOME/opencode.json"

# Unlike Claude's CLAUDE.md (hand-written, never touched above), OpenCode's AGENTS.md is both
# the live config and a tracked file: $OPENCODE_HOME is itself a stow symlink into the private
# overlay, so a stale rulesync source leaves that repo's main checkout dirty with no one
# noticing until agent-land fails to fast-forward it (ar-1397, seen landing #724). Warn here
# instead of staying silent; committing it is still a deliberate step, landed like any other
# change under the stow split (dotfiles-land), not a bare commit this script makes for you.
# -C "$OPENCODE_HOME" (not the resolved repo root) so the pathspec stays inside what git sees
# as the repo: rev-parse dereferences the stow symlink, but a path built from it would not.
opencode_repo="$(git -C "$OPENCODE_HOME" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$opencode_repo" ] && [ -n "$(git -C "$OPENCODE_HOME" status --porcelain -- AGENTS.md 2>/dev/null)" ]; then
    echo "note: $OPENCODE_HOME/AGENTS.md changed and left $opencode_repo dirty." >&2
    echo "  Land it there (dotfiles-land) before anything tries to fast-forward its main -" >&2
    echo "  agent-land cannot otherwise." >&2
fi

# Mirror Claude agents + commands into OpenCode (skills/rules are read natively
# by OpenCode from ~/.claude; agents/commands have no compat path).
"$DOTFILES_ROOT/.config/codex/sync-opencode-claude-assets.sh"
