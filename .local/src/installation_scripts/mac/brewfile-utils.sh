#!/usr/bin/env bash

# Brewfile Utility Script
# Helps manage Homebrew packages via Brewfile

set -e

BREWFILE_PATH="$HOME/.dotfiles/.config/brewfile/Brewfile"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Commands
case "${1:-help}" in
    dump)
        echo -e "${BLUE}Dumping current Homebrew state to Brewfile...${NC}"
        brew bundle dump --force --file="$BREWFILE_PATH"
        echo -e "${GREEN}✓ Brewfile updated at: $BREWFILE_PATH${NC}"
        ;;
    
    install)
        echo -e "${BLUE}Installing from Brewfile...${NC}"
        brew bundle install --file="$BREWFILE_PATH" --no-lock
        echo -e "${GREEN}✓ Installation complete${NC}"
        ;;
    
    cleanup)
        echo -e "${BLUE}Removing packages not in Brewfile...${NC}"
        brew bundle cleanup --force --file="$BREWFILE_PATH"
        echo -e "${GREEN}✓ Cleanup complete${NC}"
        ;;
    
    check)
        echo -e "${BLUE}Checking Brewfile status...${NC}"
        brew bundle check --file="$BREWFILE_PATH" --verbose
        ;;
    
    list)
        echo -e "${BLUE}Current Brewfile contents:${NC}"
        cat "$BREWFILE_PATH"
        ;;
    
    edit)
        ${EDITOR:-vim} "$BREWFILE_PATH"
        ;;
    
    diff)
        echo -e "${BLUE}Differences between system and Brewfile:${NC}"
        echo -e "${YELLOW}Installed but not in Brewfile:${NC}"
        comm -13 <(brew bundle list --file="$BREWFILE_PATH" | sort) <(brew list --formula | sort)
        echo ""
        echo -e "${YELLOW}In Brewfile but not installed:${NC}"
        comm -23 <(brew bundle list --file="$BREWFILE_PATH" | sort) <(brew list --formula | sort)
        ;;
    
    help|*)
        echo "Brewfile Utility Script"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  dump     - Save current Homebrew state to Brewfile"
        echo "  install  - Install everything from Brewfile"
        echo "  cleanup  - Remove packages not in Brewfile"
        echo "  check    - Check if Brewfile dependencies are satisfied"
        echo "  list     - Display Brewfile contents"
        echo "  edit     - Open Brewfile in editor"
        echo "  diff     - Show differences between system and Brewfile"
        echo ""
        echo "Brewfile location: $BREWFILE_PATH"
        ;;
esac