#!/usr/bin/env bash

# Universal Installation Script
# Detects the system and runs the appropriate installation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print header
print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}        Universal Installation Script           ${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

# Detect the operating system
detect_os() {
    local os_type=""

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                debian|ubuntu|pop|mint)
                    os_type="debian"
                    ;;
                arch|manjaro|endeavouros|cachyos)
                    os_type="arch"
                    ;;
                *)
                    echo -e "${YELLOW}Unknown Linux distribution: $ID${NC}"
                    os_type="unknown"
                    ;;
            esac
        elif [ -f /etc/debian_version ]; then
            os_type="debian"
        elif [ -f /etc/arch-release ]; then
            os_type="arch"
        else
            os_type="unknown"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        os_type="mac"
    elif [[ "$OSTYPE" == "linux-android"* ]] || [ -d /data/data/com.termux ]; then
        # Android/Termux
        os_type="android"
    elif [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]] || [ -n "$WINDIR" ]; then
        # Native Windows (Git Bash / Cygwin / MSYS). WSL reports linux-gnu
        # and is handled above as Debian/Arch — that's correct.
        os_type="windows"
    else
        os_type="unknown"
    fi

    echo "$os_type"
}

# Show menu for manual selection
show_menu() {
    echo -e "${GREEN}Please select your system:${NC}"
    echo "1) Debian/Ubuntu"
    echo "2) Arch Linux"
    echo "3) macOS"
    echo "4) Android/Termux"
    echo "5) Exit"
    echo ""
    read -p "Enter choice [1-5]: " choice

    case $choice in
        1) echo "debian" ;;
        2) echo "arch" ;;
        3) echo "mac" ;;
        4) echo "android" ;;
        5) exit 0 ;;
        *) echo "invalid" ;;
    esac
}

# Main execution
main() {
    # Parse flags. --no-sudo / --no-root makes the install run without a root
    # password by exporting NO_SUDO=1, which the OS-specific installers honor
    # (on macOS, macos_defaults.sh skips its privileged steps). Exported so it
    # reaches child scripts like macos_defaults.sh.
    # Module flags become INSTALL_* env vars, read by base_functions.sh::step.
    export INSTALL_MODE=run
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-sudo|--no-root)
                export NO_SUDO=1
                echo -e "${YELLOW}--no-sudo: privileged steps will be skipped (no root password needed)${NC}"
                shift
                ;;
            --only|--with|--without)
                [[ -n "${2:-}" ]] || { echo -e "${RED}$1 needs a module list, e.g. $1 music${NC}"; exit 1; }
                set -- "$1=$2" "${@:3}"
                ;;
            --only=*)    export INSTALL_ONLY="${1#*=}"; shift ;;
            --with=*)    export INSTALL_WITH="${1#*=}"; shift ;;
            --without=*) export INSTALL_WITHOUT="${1#*=}"; shift ;;
            --list)      INSTALL_MODE=list; shift ;;
            --dry-run)   INSTALL_MODE=dry-run; shift ;;
            -h|--help)
                echo "Usage: install.sh [--no-sudo] [--list] [--dry-run] [--only a,b | --with a,b] [--without a,b]"
                echo "  --no-sudo, --no-root   Skip every step that needs a root password"
                echo "  --list                 Show this OS's modules and which run by default"
                echo "  --dry-run              Print the steps that would run, install nothing"
                echo "  --only a,b             Run just these modules (e.g. --only music)"
                echo "  --with a,b             Add opt-in modules to the default set"
                echo "  --without a,b          Drop modules from the default set"
                exit 0
                ;;
            *)
                echo -e "${YELLOW}Ignoring unknown argument: $1${NC}"
                shift
                ;;
        esac
    done

    print_header

    # Detect OS
    echo -e "${GREEN}Detecting operating system...${NC}"
    os_type=$(detect_os)

    if [ "$os_type" == "unknown" ] || [ "$os_type" == "invalid" ]; then
        echo -e "${YELLOW}Could not auto-detect OS${NC}"
        os_type=$(show_menu)
        while [ "$os_type" == "invalid" ]; do
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            os_type=$(show_menu)
        done
    fi

    echo -e "${GREEN}System detected: ${BLUE}$os_type${NC}"
    echo ""

    # Ask for confirmation (listing and dry runs change nothing)
    if [[ "$INSTALL_MODE" == run ]]; then
        read -p "Do you want to proceed with installation? (y/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Installation cancelled${NC}"
            exit 0
        fi
    fi

    # Run the appropriate OS-specific installer
    case "$os_type" in
        debian)
            source "$SCRIPT_DIR/linux/install_debian.sh"
            ;;
        arch)
            source "$SCRIPT_DIR/linux/install_arch.sh"
            ;;
        mac)
            source "$SCRIPT_DIR/mac/install_mac.sh"
            ;;
        android)
            source "$SCRIPT_DIR/android/install_android.sh"
            ;;
        windows)
            echo -e "${YELLOW}Bash can't drive the Windows installer.${NC}"
            echo -e "Open PowerShell and run:"
            echo -e "${BLUE}  & \"$SCRIPT_DIR/windows/install_windows.ps1\"${NC}"
            echo -e "Or use the bootstrap one-liner — see windows/README.md."
            exit 0
            ;;
        *)
            echo -e "${RED}Unsupported system: $os_type${NC}"
            exit 1
            ;;
    esac

    # Run the installation (the OS installer prints its own completion notes)
    run_install
}

# Run main function
main "$@"