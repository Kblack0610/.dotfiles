#!/usr/bin/env bash

# Package Manager Detection Utility
# This script detects the system's package manager and sets appropriate variables

function detect_package_manager() {
    if command -v pacman &> /dev/null; then
        PACKAGE_MANAGER="pacman"
        PACKAGE_INSTALL_CMD="sudo pacman -S --noconfirm"
        PACKAGE_UPDATE_CMD="sudo pacman -Syu --noconfirm"
        PACKAGE_SEARCH_CMD="pacman -Ss"
        DISTRIBUTION="arch"
    elif command -v apt &> /dev/null; then
        PACKAGE_MANAGER="apt"
        PACKAGE_INSTALL_CMD="sudo apt install -y"
        PACKAGE_UPDATE_CMD="sudo apt update && sudo apt upgrade -y"
        PACKAGE_SEARCH_CMD="apt search"
        DISTRIBUTION="debian"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
        PACKAGE_INSTALL_CMD="sudo dnf install -y"
        PACKAGE_UPDATE_CMD="sudo dnf update -y"
        PACKAGE_SEARCH_CMD="dnf search"
        DISTRIBUTION="fedora"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
        PACKAGE_INSTALL_CMD="sudo yum install -y"
        PACKAGE_UPDATE_CMD="sudo yum update -y"
        PACKAGE_SEARCH_CMD="yum search"
        DISTRIBUTION="rhel"
    elif command -v zypper &> /dev/null; then
        PACKAGE_MANAGER="zypper"
        PACKAGE_INSTALL_CMD="sudo zypper install -y"
        PACKAGE_UPDATE_CMD="sudo zypper update -y"
        PACKAGE_SEARCH_CMD="zypper search"
        DISTRIBUTION="opensuse"
    elif command -v emerge &> /dev/null; then
        PACKAGE_MANAGER="emerge"
        PACKAGE_INSTALL_CMD="sudo emerge"
        PACKAGE_UPDATE_CMD="sudo emerge --sync && sudo emerge -uDN @world"
        PACKAGE_SEARCH_CMD="emerge --search"
        DISTRIBUTION="gentoo"
    else
        echo "No supported package manager found!"
        echo "Supported package managers: pacman, apt, dnf, yum, zypper, emerge"
        exit 1
    fi

    echo "Detected package manager: $PACKAGE_MANAGER"
    echo "Distribution: $DISTRIBUTION"
    
    # Export variables for use in other scripts
    export PACKAGE_MANAGER
    export PACKAGE_INSTALL_CMD
    export PACKAGE_UPDATE_CMD
    export PACKAGE_SEARCH_CMD
    export DISTRIBUTION
}

# If script is run directly, detect and display package manager info
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_package_manager
    echo ""
    echo "Package manager variables set:"
    echo "PACKAGE_MANAGER=$PACKAGE_MANAGER"
    echo "PACKAGE_INSTALL_CMD=$PACKAGE_INSTALL_CMD"
    echo "PACKAGE_UPDATE_CMD=$PACKAGE_UPDATE_CMD"
    echo "PACKAGE_SEARCH_CMD=$PACKAGE_SEARCH_CMD"
    echo "DISTRIBUTION=$DISTRIBUTION"
fi 