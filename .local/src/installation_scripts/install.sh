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
                arch|manjaro|endeavouros)
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

    # Ask for confirmation
    read -p "Do you want to proceed with installation? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installation cancelled${NC}"
        exit 0
    fi

    # Source the agnostic script
    source "$SCRIPT_DIR/install_requirements_agnostic.sh"

    # Run installation based on system type
    case "$os_type" in
        debian)
            if [ -f "$SCRIPT_DIR/linux/debian/install_requirements_functions_new.sh" ]; then
                source "$SCRIPT_DIR/linux/debian/install_requirements_functions_new.sh"
                install_all_debian
            else
                # Fallback to agnostic installation
                install_all "debian"
            fi
            ;;
        arch)
            if [ -f "$SCRIPT_DIR/linux/arch/install_requirements_functions_new.sh" ]; then
                source "$SCRIPT_DIR/linux/arch/install_requirements_functions_new.sh"
                install_all_arch
            else
                # Fallback to agnostic installation
                install_all "arch"
            fi
            ;;
        mac)
            if [ -f "$SCRIPT_DIR/mac/install_requirements_functions_new.sh" ]; then
                source "$SCRIPT_DIR/mac/install_requirements_functions_new.sh"
                install_all_mac
            else
                # Fallback to agnostic installation
                install_all "mac"
            fi
            ;;
        android)
            if [ -f "$SCRIPT_DIR/android/install_android_functions_new.sh" ]; then
                source "$SCRIPT_DIR/android/install_android_functions_new.sh"
                install_all_termux
            else
                # Fallback to agnostic installation
                install_all "android"
            fi
            ;;
        *)
            echo -e "${RED}Unsupported system: $os_type${NC}"
            exit 1
            ;;
    esac

    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}          Installation Complete!                ${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo -e "${YELLOW}Please restart your terminal or run:${NC}"
    echo -e "${BLUE}  source ~/.zshrc${NC}"
    echo ""
}

# Run main function
main "$@"