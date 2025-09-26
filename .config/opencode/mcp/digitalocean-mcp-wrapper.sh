#!/bin/bash
# Wrapper script for DigitalOcean MCP to properly pass environment variables
export DIGITALOCEAN_API_TOKEN="$DIGITALOCEAN_API_TOKEN"
exec npx @digitalocean/mcp "$@"
