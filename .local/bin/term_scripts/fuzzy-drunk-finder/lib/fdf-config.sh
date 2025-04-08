#!/bin/bash
# fdf-config.sh - Configuration management for Fuzzy Drunk Finder
# This module handles loading and saving user configuration settings

# Default configuration values
DEFAULT_DEPTH=3
DEFAULT_SHOW_HIDDEN=false
DEFAULT_USE_HISTORY=true
DEFAULT_CACHE_TIMEOUT=3600  # 1 hour in seconds
DEFAULT_MAX_DEPTH_HOME=7    # Max depth for home directories

# Configuration paths
USER_CONFIG_FILE="$HOME/.config/fdf/config"
SYSTEM_CONFIG_FILE="/etc/fdf/config"
LOCAL_CONFIG_FILE="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/.fdf_config"

# Function to load configuration from files
load_config() {
    # Start with default values
    DEPTH="$DEFAULT_DEPTH"
    SHOW_HIDDEN="$DEFAULT_SHOW_HIDDEN"
    USE_HISTORY="$DEFAULT_USE_HISTORY"
    CACHE_TIMEOUT="$DEFAULT_CACHE_TIMEOUT"
    MAX_DEPTH_HOME="$DEFAULT_MAX_DEPTH_HOME"
    
    # Try loading from system config first (lowest priority)
    if [ -f "$SYSTEM_CONFIG_FILE" ]; then
        source "$SYSTEM_CONFIG_FILE"
    fi
    
    # Then try local config (middle priority)
    if [ -f "$LOCAL_CONFIG_FILE" ]; then
        source "$LOCAL_CONFIG_FILE"
    fi
    
    # Finally try user config (highest priority)
    if [ -f "$USER_CONFIG_FILE" ]; then
        source "$USER_CONFIG_FILE"
    fi
}

# Function to create a default user configuration file
create_default_config() {
    local config_dir="$(dirname "$USER_CONFIG_FILE")"
    
    # Create config directory if it doesn't exist
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
    fi
    
    # Create default config file with comments
    if [ ! -f "$USER_CONFIG_FILE" ]; then
        cat > "$USER_CONFIG_FILE" << EOL
# Fuzzy Drunk Finder Configuration File
# Created on $(date)

# Default depth for directory searches (default: 3)
# DEPTH=3

# Show hidden directories by default (true/false, default: false)
# SHOW_HIDDEN=false

# Use and update directory history (true/false, default: true)
# USE_HISTORY=true

# Cache timeout in seconds (default: 3600 = 1 hour)
# CACHE_TIMEOUT=3600

# Maximum depth for home directories when unlimited is set (default: 7)
# MAX_DEPTH_HOME=7
EOL
        echo "Created default configuration file at $USER_CONFIG_FILE"
    else
        echo "Configuration file already exists at $USER_CONFIG_FILE"
    fi
}

# Function to edit the user configuration
fdf_config() {
    # Create default config if it doesn't exist
    if [ ! -f "$USER_CONFIG_FILE" ]; then
        create_default_config
    fi
    
    # Open the config file in the default editor
    if [ -n "$EDITOR" ]; then
        "$EDITOR" "$USER_CONFIG_FILE"
    elif command -v nano >/dev/null 2>&1; then
        nano "$USER_CONFIG_FILE"
    elif command -v vim >/dev/null 2>&1; then
        vim "$USER_CONFIG_FILE"
    else
        echo "No suitable editor found. Please edit $USER_CONFIG_FILE manually."
    fi
    
    echo "Configuration updated. Changes will take effect on next use."
}
