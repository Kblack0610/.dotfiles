#!/bin/zsh

# Minimal zsh configuration script that only sets up important paths

# Basic environment setup
export PATH="$PATH:$HOME/.local/bin"

# Node version manager
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Go path
if [ -d "/usr/local/go/bin" ]; then
    export PATH=$PATH:/usr/local/go/bin
fi

# Cargo path from bash_profile
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# .NET tools
export PATH="$PATH:$HOME/.dotnet/tools"

# Maestro path
export PATH=$PATH:$HOME/.maestro/bin

# Android SDK
export ANDROID_HOME=/usr/lib/android-sdk

# Add any other important custom paths here
export PATH=$PATH:$HOME/src/go/bin/bluetuith

# Basic environment variables from bash_profile
export NODE_ENV=development

# Set a simple prompt
export PS1="%n@%m:%~$ "

# Don't load any other zsh customizations, plugins, or themes
