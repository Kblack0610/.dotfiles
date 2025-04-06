#!/usr/bin/env python3
"""
Delete Git Tokens - A tool to delete stored tokens from the git-token-generator.
"""

import sys
import json
import argparse
from pathlib import Path

from rich.console import Console
from rich.prompt import Confirm
from cryptography.fernet import Fernet

# Token storage configuration
CONFIG_DIR = Path.home() / ".config" / "git-token-generator"
TOKENS_FILE = CONFIG_DIR / "tokens.json"
KEY_FILE = CONFIG_DIR / "key.key"

console = Console()


def load_key():
    """Load the encryption key."""
    if not KEY_FILE.exists():
        console.print("No encryption key found. No tokens have been generated yet.", style="yellow")
        sys.exit(1)
    
    with open(KEY_FILE, "rb") as key_file:
        return key_file.read()


def load_tokens():
    """Load tokens from storage."""
    if not TOKENS_FILE.exists():
        console.print("No tokens file found. No tokens have been generated yet.", style="yellow")
        return {}
    
    try:
        with open(TOKENS_FILE, "r") as f:
            return json.load(f)
    except Exception as e:
        console.print(f"Error loading tokens: {e}", style="red")
        return {}


def save_tokens(tokens):
    """Save tokens to storage."""
    try:
        with open(TOKENS_FILE, "w") as f:
            json.dump(tokens, f, indent=2)
        return True
    except Exception as e:
        console.print(f"Error saving tokens: {e}", style="red")
        return False


def decrypt_tokens(encrypted_tokens):
    """Decrypt tokens for display."""
    key = load_key()
    cipher = Fernet(key)
    
    tokens = {}
    for platform, entries in encrypted_tokens.items():
        tokens[platform] = []
        for entry in entries:
            try:
                decrypted_token = cipher.decrypt(entry["token"].encode()).decode()
                entry_copy = entry.copy()
                entry_copy["token"] = decrypted_token
                tokens[platform].append(entry_copy)
            except Exception as e:
                console.print(f"Error decrypting token {entry.get('name', 'unknown')}: {e}", style="red")
    
    return tokens


def display_token_summary(tokens, platform=None, name=None):
    """Display a summary of tokens that will be deleted."""
    filtered_tokens = {}
    
    # Apply filters
    for plat, platform_tokens in tokens.items():
        if platform and platform != plat:
            continue
            
        filtered_plat_tokens = []
        for token in platform_tokens:
            if name and token.get("name") != name:
                continue
            filtered_plat_tokens.append(token)
            
        if filtered_plat_tokens:
            filtered_tokens[plat] = filtered_plat_tokens
    
    if not filtered_tokens:
        console.print("No tokens match the specified criteria.", style="yellow")
        return None
    
    # Show summary
    console.print("The following tokens will be deleted:", style="yellow")
    for plat, platform_tokens in filtered_tokens.items():
        console.print(f"\n{plat}:", style="bold")
        for token in platform_tokens:
            token_name = token.get("name", "Unknown")
            created_at = token.get("created_at", "Unknown date")
            console.print(f"  - {token_name} (created: {created_at})")
    
    return filtered_tokens


def delete_tokens(all_tokens, platform=None, name=None, force=False):
    """Delete tokens based on filters."""
    # Get a decrypted copy for display
    decrypted_tokens = decrypt_tokens(all_tokens)
    
    # Display summary and confirm
    filtered_tokens = display_token_summary(decrypted_tokens, platform, name)
    if not filtered_tokens:
        return False
    
    if not force and not Confirm.ask("\nAre you sure you want to delete these tokens?"):
        console.print("Operation cancelled.", style="yellow")
        return False
    
    # Perform deletion
    modified = False
    for plat in list(all_tokens.keys()):
        if platform and platform != plat:
            continue
            
        if name:
            # Delete specific tokens by name
            all_tokens[plat] = [t for t in all_tokens[plat] if t.get("name") != name]
            modified = True
        else:
            # Delete all tokens for this platform
            del all_tokens[plat]
            modified = True
    
    # Remove empty platform entries
    for plat in list(all_tokens.keys()):
        if not all_tokens[plat]:
            del all_tokens[plat]
    
    if modified:
        if save_tokens(all_tokens):
            console.print("Tokens deleted successfully.", style="green")
            return True
    else:
        console.print("No changes made.", style="yellow")
    
    return False


def main():
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(description="Delete stored Git tokens")
    parser.add_argument("--platform", choices=["github", "gitlab", "bitbucket"], 
                      help="Platform to delete tokens for")
    parser.add_argument("--name", help="Delete tokens with this name")
    parser.add_argument("--all", action="store_true", 
                      help="Delete all tokens (must be used with --force)")
    parser.add_argument("--force", action="store_true", 
                      help="Force deletion without confirmation")
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.all and not (args.force and not args.name and not args.platform):
        console.print("When using --all, you must use --force and cannot specify --name or --platform", 
                    style="red")
        sys.exit(1)
    
    if not args.platform and not args.name and not args.all:
        console.print("You must specify at least one filter: --platform, --name, or --all", 
                    style="yellow")
        parser.print_help()
        sys.exit(1)
    
    # Load tokens
    all_tokens = load_tokens()
    if not all_tokens:
        sys.exit(1)
    
    if args.all:
        # Delete all tokens
        if Confirm.ask("Are you sure you want to delete ALL tokens? This cannot be undone.", 
                      default=False):
            save_tokens({})
            console.print("All tokens deleted successfully.", style="green")
        else:
            console.print("Operation cancelled.", style="yellow")
    else:
        # Delete filtered tokens
        delete_tokens(all_tokens, args.platform, args.name, args.force)


if __name__ == "__main__":
    main()
