#!/bin/bash
# Auto-configure personal MCP servers and plans on first run

# Clean stale compliance guard files from previous sessions
rm -f /tmp/claude-rules-guards/compliance-* 2>/dev/null

MARKER_FILE="$HOME/.claude-mcp-configured"
PLANS_MARKER="$HOME/.claude-plans-configured"

# Setup MCP servers (existing installs)
if [ ! -f "$MARKER_FILE" ]; then
    # Add Linear MCP (user scope = applies to all projects on this device)
    claude mcp add --scope user linear -- npx -y mcp-remote https://mcp.linear.app/mcp
    touch "$MARKER_FILE"
fi

# Setup plans symlink (fallback for existing installations)
if [ ! -f "$PLANS_MARKER" ]; then
    PLANS_TARGET="$HOME/.agent/plans"
    PLANS_LINK="$HOME/.claude/plans"

    mkdir -p "$PLANS_TARGET"

    if [ ! -L "$PLANS_LINK" ] && [ -d "$PLANS_LINK" ]; then
        mv "$PLANS_LINK" "${PLANS_LINK}.bak"
    fi

    if [ ! -L "$PLANS_LINK" ]; then
        ln -s "$PLANS_TARGET" "$PLANS_LINK"
    fi

    touch "$PLANS_MARKER"
fi
