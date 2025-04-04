#!/usr/bin/env bash

# symlink_factory.sh
# A flexible script to create symlinks for configuration files across multiple directories
# Usage: ./symlink_factory.sh [OPTIONS] SOURCE_FILE... TARGET_DIR...
#
# Options:
#   -h, --help                Display this help message
#   -f, --force               Force overwrite of existing symlinks
#   -v, --verbose             Enable verbose output
#   -b, --backup              Create backup of existing files before overwriting
#   -s, --source-dir DIR      Source directory (default: current directory)
#   -n, --dry-run             Show what would be done without making changes
#   --files-list FILE         Read source files from FILE (one per line)
#   --dirs-list FILE          Read target directories from FILE (one per line)

set -e

# Default values
FORCE=0
VERBOSE=0
BACKUP=0
DRY_RUN=0
SOURCE_DIR="$(pwd)"
FILES_LIST=""
DIRS_LIST=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display error messages
error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    exit 1
}

# Function to display warning messages
warning() {
    echo -e "${YELLOW}WARNING:${NC} $1" >&2
}

# Function to display info messages
info() {
    if [ $VERBOSE -eq 1 ]; then
        echo -e "${BLUE}INFO:${NC} $1"
    fi
}

# Function to display success messages
success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

# Function to read lines from a file into an array
read_lines_from_file() {
    local file="$1"
    local array_name="$2"
    local line
    
    if [ ! -f "$file" ]; then
        error "File not found: $file"
    fi
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
            # Trim leading/trailing whitespace
            line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            eval "$array_name+=(\"$line\")"
        fi
    done < "$file"
}

# Parse command line arguments
parse_args() {
    SOURCE_FILES=()
    TARGET_DIRS=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -b|--backup)
                BACKUP=1
                shift
                ;;
            -s|--source-dir)
                if [[ -z "$2" || "$2" == -* ]]; then
                    error "Option --source-dir requires a directory path"
                fi
                SOURCE_DIR="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            --files-list)
                if [[ -z "$2" || "$2" == -* ]]; then
                    error "Option --files-list requires a file path"
                fi
                FILES_LIST="$2"
                shift 2
                ;;
            --dirs-list)
                if [[ -z "$2" || "$2" == -* ]]; then
                    error "Option --dirs-list requires a file path"
                fi
                DIRS_LIST="$2"
                shift 2
                ;;
            -*)
                error "Unknown option: $1"
                ;;
            *)
                if [[ -e "$SOURCE_DIR/$1" || -e "$1" ]]; then
                    # It's a source file
                    SOURCE_FILES+=("$1")
                elif [[ -d "$1" ]]; then
                    # It's a target directory
                    TARGET_DIRS+=("$1")
                else
                    # Assume it's a target directory that doesn't exist yet
                    warning "Directory does not exist: $1. Will create if needed."
                    TARGET_DIRS+=("$1")
                fi
                shift
                ;;
        esac
    done
    
    # Read source files from file if specified
    if [[ -n "$FILES_LIST" ]]; then
        info "Reading source files from: $FILES_LIST"
        read_lines_from_file "$FILES_LIST" "SOURCE_FILES"
    fi
    
    # Read target directories from file if specified
    if [[ -n "$DIRS_LIST" ]]; then
        info "Reading target directories from: $DIRS_LIST"
        read_lines_from_file "$DIRS_LIST" "TARGET_DIRS"
    fi
    
    # Check if required arguments are provided
    if [[ ${#SOURCE_FILES[@]} -eq 0 ]]; then
        error "No source files specified. Use command line arguments or --files-list"
    fi
    
    if [[ ${#TARGET_DIRS[@]} -eq 0 ]]; then
        error "No target directories specified. Use command line arguments or --dirs-list"
    fi
}

# Function to show help message
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] SOURCE_FILE... TARGET_DIR...

Create symlinks for specified files in multiple target directories.

Options:
  -h, --help                Display this help message
  -f, --force               Force overwrite of existing symlinks
  -v, --verbose             Enable verbose output
  -b, --backup              Create backup of existing files before overwriting
  -s, --source-dir DIR      Source directory (default: current directory)
  -n, --dry-run             Show what would be done without making changes
  --files-list FILE         Read source files from FILE (one per line)
  --dirs-list FILE          Read target directories from FILE (one per line)

Examples:
  $(basename "$0") windsurf.rules cursor.rules ~/.config/rules/ /etc/rules/
  $(basename "$0") -s ~/configs -f *.conf /etc/config/ ~/.local/config/
  $(basename "$0") --files-list ~/files.txt --dirs-list ~/dirs.txt
  
File list format:
  Each line contains one file path or directory path.
  Empty lines and lines starting with # are ignored.
EOF
}

# Function to create a symlink
create_symlink() {
    local source_file="$1"
    local target_dir="$2"
    local basename_source="$(basename "$source_file")"
    local target_file="$target_dir/$basename_source"
    local source_path
    
    # Determine absolute source path
    if [[ "$source_file" == /* ]]; then
        source_path="$source_file"
    else
        source_path="$SOURCE_DIR/$source_file"
    fi
    
    # Create target directory if it doesn't exist
    if [[ ! -d "$target_dir" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            info "Would create directory: $target_dir"
        else
            info "Creating directory: $target_dir"
            mkdir -p "$target_dir" || error "Failed to create directory: $target_dir"
        fi
    fi
    
    # Check if target already exists
    if [[ -e "$target_file" || -L "$target_file" ]]; then
        if [[ $FORCE -eq 1 ]]; then
            if [[ $BACKUP -eq 1 ]]; then
                if [[ $DRY_RUN -eq 1 ]]; then
                    info "Would back up: $target_file to $target_file.bak"
                else
                    info "Backing up: $target_file to $target_file.bak"
                    cp -a "$target_file" "$target_file.bak" || warning "Failed to create backup: $target_file.bak"
                fi
            fi
            
            if [[ $DRY_RUN -eq 1 ]]; then
                info "Would remove existing file: $target_file"
            else
                info "Removing existing file: $target_file"
                rm -f "$target_file" || error "Failed to remove: $target_file"
            fi
        else
            warning "File already exists: $target_file. Use --force to overwrite."
            return 1
        fi
    fi
    
    # Create symlink
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would symlink: $source_path -> $target_file"
    else
        info "Creating symlink: $source_path -> $target_file"
        ln -s "$source_path" "$target_file" || error "Failed to create symlink: $target_file"
        success "Created symlink: $basename_source -> $target_dir"
    fi
    
    return 0
}

# Main function
main() {
    # Parse command line arguments
    parse_args "$@"
    
    # Print summary of what will be done
    local source_count=${#SOURCE_FILES[@]}
    local target_count=${#TARGET_DIRS[@]}
    local total_links=$((source_count * target_count))
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "DRY RUN: No changes will be made"
    fi
    
    info "Source directory: $SOURCE_DIR"
    info "Source files ($source_count): ${SOURCE_FILES[*]}"
    info "Target directories ($target_count): ${TARGET_DIRS[*]}"
    info "Will create up to $total_links symlinks"
    
    # Create symlinks
    local success_count=0
    local fail_count=0
    
    for target_dir in "${TARGET_DIRS[@]}"; do
        for source_file in "${SOURCE_FILES[@]}"; do
            if create_symlink "$source_file" "$target_dir"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        done
    done
    
    # Print summary
    if [[ $DRY_RUN -eq 1 ]]; then
        success "DRY RUN: Would create $success_count symlinks ($fail_count skipped)"
    else
        success "Created $success_count symlinks ($fail_count skipped)"
    fi
}

# Run the script
main "$@"
