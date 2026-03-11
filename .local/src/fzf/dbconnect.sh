#!/usr/bin/env bash
#
# dbconnect - scan for database connections and launch rainfrog
#
# Usage: dbconnect [directory]
#   Scans the given directory (default: cwd) for .env files and
#   docker-compose*.yml, extracts DB connection strings, presents
#   them via fzf, and launches rainfrog with the selected URL.
#
# Self-call: dbconnect --preview <url>
#   Used internally by fzf to render the preview panel.

set -euo pipefail

# ── Preview mode (self-call from fzf) ───────────────────────────
if [[ "${1:-}" == "--preview" ]]; then
    url="$2"
    # Parse URL: driver://user:pass@host:port/dbname
    if [[ "$url" =~ ^([a-z]+)://([^:]+):([^@]*)@([^:]+):([0-9]+)/(.+)$ ]]; then
        driver="${BASH_REMATCH[1]}"
        user="${BASH_REMATCH[2]}"
        host="${BASH_REMATCH[4]}"
        port="${BASH_REMATCH[5]}"
        dbname="${BASH_REMATCH[6]}"
        dbname="${dbname%%\?*}"
        echo "  Driver:   $driver"
        echo "  Host:     $host"
        echo "  Port:     $port"
        echo "  Database: $dbname"
        echo "  User:     $user"
    else
        echo "  URL: $url"
    fi
    exit 0
fi

SEARCH_DIR="${1:-.}"
SEARCH_DIR="$(cd "$SEARCH_DIR" && pwd)"

# ── Helpers ─────────────────────────────────────────────────────

mask_url() {
    echo "$1" | sed -E 's|://([^:]+):[^@]*@|://\1:****@|'
}

# Emit tab-delimited fzf entry: <raw_url>\t<display_label>
emit_entry() {
    printf '%s\t%s  %s\n' "$1" "$2" "$(mask_url "$1")"
}

# Resolve ${VAR:-default} syntax, strip remaining var refs and quotes
resolve_value() {
    local val="$1"
    val="$(echo "$val" | sed -E 's/\$\{[^:}]+:-([^}]+)\}/\1/g')"
    val="$(echo "$val" | sed -E 's/\$\{[^}]+\}//g; s/\$[A-Za-z_][A-Za-z0-9_]*//g')"
    val="$(echo "$val" | sed -E "s/^['\"]//; s/['\"]$//")"
    echo "$val"
}

# Extract a key=value from an env file
env_get() {
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2- || true
}

# ── Scan .env files ─────────────────────────────────────────────

declare -a entries=()

scan_env_files() {
    local url_vars="DATABASE_URL|DB_URL|POSTGRES_URL|POSTGRESQL_URL|MYSQL_URL"

    while IFS= read -r envfile; do
        [[ -f "$envfile" ]] || continue
        local relpath="${envfile#"$SEARCH_DIR"/}"

        # 1) Full URL vars
        while IFS='=' read -r key val; do
            [[ -z "$val" ]] && continue
            val="$(resolve_value "$val")"
            [[ -z "$val" || "$val" != *"://"* ]] && continue
            entries+=("$(emit_entry "$val" "$relpath ($key)")")
        done < <(grep -E "^(${url_vars})=" "$envfile" 2>/dev/null || true)

        # 2) Component vars → construct URL from parts
        local host="" port="" dbname="" user="" password=""

        for prefix in DB POSTGRES PG POSTGRESQL; do
            local v
            v="$(env_get "$envfile" "${prefix}_HOST")"
            [[ -n "$v" ]] && host="$(resolve_value "$v")"
            v="$(env_get "$envfile" "${prefix}_PORT")"
            [[ -n "$v" ]] && port="$(resolve_value "$v")"

            for suffix in NAME DB DATABASE; do
                v="$(env_get "$envfile" "${prefix}_${suffix}")"
                [[ -n "$v" ]] && { dbname="$(resolve_value "$v")"; break; }
            done

            for suffix in USER USERNAME; do
                v="$(env_get "$envfile" "${prefix}_${suffix}")"
                [[ -n "$v" ]] && { user="$(resolve_value "$v")"; break; }
            done

            for suffix in PASSWORD PASS; do
                v="$(env_get "$envfile" "${prefix}_${suffix}")"
                [[ -n "$v" ]] && { password="$(resolve_value "$v")"; break; }
            done
        done

        if [[ -n "$host" && -n "$dbname" && -n "$user" ]]; then
            local constructed="postgres://${user}:${password:-}@${host}:${port:-5432}/${dbname}"
            entries+=("$(emit_entry "$constructed" "$relpath (constructed)")")
        fi

    done < <(find "$SEARCH_DIR" -maxdepth 6 \
             \( -name node_modules -o -name .git -o -name vendor -o -name .venv \
                -o -name __pycache__ -o -name .tox -o -name .mypy_cache \
                -o -name dist -o -name build -o -name .next \) -prune \
             -o \( -name '.env' -o -name '.env.*' -o -name '*.env' \) -print 2>/dev/null | \
             grep -v -E '\.env\.(example|sample|template)$' | sort)
}

# ── Scan docker-compose files ───────────────────────────────────

scan_compose_files() {
    while IFS= read -r composefile; do
        [[ -f "$composefile" ]] || continue
        local relpath="${composefile#"$SEARCH_DIR"/}"
        local pg_user="" pg_password="" pg_db="" host_port=""

        while IFS=':' read -r key val; do
            key="$(echo "$key" | xargs)"
            val="$(echo "$val" | xargs)"
            val="$(resolve_value "$val")"
            case "$key" in
                POSTGRES_USER)     pg_user="$val" ;;
                POSTGRES_PASSWORD) pg_password="$val" ;;
                POSTGRES_DB)       pg_db="$val" ;;
            esac
        done < <(grep -E '^\s*(POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB)\s*[:=]' "$composefile" 2>/dev/null || true)

        host_port="$(grep -E '^\s*-?\s*["\x27]?[0-9]+:5432' "$composefile" 2>/dev/null \
                     | head -1 | sed -E "s/.*[\"']?([0-9]+):5432.*/\1/"; true)"

        if [[ -n "$pg_user" && -n "$pg_db" ]]; then
            local url="postgres://${pg_user}:${pg_password:-}@localhost:${host_port:-5432}/${pg_db}"
            entries+=("$(emit_entry "$url" "$relpath (docker)")")
        fi
    done < <(find "$SEARCH_DIR" -maxdepth 6 \
             \( -name node_modules -o -name .git -o -name vendor -o -name .venv \
                -o -name __pycache__ -o -name .tox -o -name .mypy_cache \
                -o -name dist -o -name build -o -name .next \) -prune \
             -o \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
                -o -name 'compose*.yml' -o -name 'compose*.yaml' \) -print 2>/dev/null | sort)
}

# ── Main ────────────────────────────────────────────────────────

scan_env_files
scan_compose_files

if [[ ${#entries[@]} -eq 0 ]]; then
    echo "No database connections found in: $SEARCH_DIR"
    exit 1
fi

# Build fzf input
fzf_input=""
for entry in "${entries[@]}"; do
    fzf_input+="${entry}"$'\n'
done

selected="$(echo -n "$fzf_input" | fzf \
    --reverse --border --cycle \
    --prompt='Select database > ' \
    --height=50% \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=2 \
    --preview="$0 --preview {1}" \
    --preview-window=up:6:wrap \
    --header='Enter=connect | esc=cancel')"

if [[ -z "$selected" ]]; then
    echo "No selection made."
    exit 0
fi

url="$(echo "$selected" | cut -f1)"

echo "Connecting to: $(mask_url "$url")"
exec rainfrog --url "$url"
