#!/bin/bash
# Wrapper script for GitHub MCP to properly pass environment variables to Docker
exec docker run -i --rm \
  -e GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN" \
  ghcr.io/github/github-mcp-server "$@"