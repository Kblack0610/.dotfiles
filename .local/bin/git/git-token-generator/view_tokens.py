#!/usr/bin/env python3
"""
View Git Tokens - A tool to view stored tokens from the git-token-generator.
"""

import sys
import json
import argparse
from pathlib import Path

from rich.console import Console
from rich.table import Table
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
    """Load and decrypt tokens from storage."""
    if not TOKENS_FILE.exists():
        console.print("No tokens file found. No tokens have been generated yet.", style="yellow")
        return {}
    
    try:
        with open(TOKENS_FILE, "r") as f:
            encrypted_data = json.load(f)
        
        # Get the cipher for decryption
        key = load_key()
        cipher = Fernet(key)
        
        # Decrypt the tokens
        tokens = {}
        for platform, entries in encrypted_data.items():
            tokens[platform] = []
            for entry in entries:
                decrypted_token = cipher.decrypt(entry["token"].encode()).decode()
                entry["token"] = decrypted_token
                tokens[platform].append(entry)
        
        return tokens
    
    except Exception as e:
        console.print(f"Error loading tokens: {e}", style="red")
        return {}


def display_tokens(tokens, platform=None, show_values=False, name=None):
    """Display tokens in a formatted table."""
    # Filter by platform if specified
    if platform:
        tokens = {platform: tokens.get(platform, [])}
    
    for plat, platform_tokens in tokens.items():
        if not platform_tokens:
            console.print(f"No tokens found for {plat}", style="yellow")
            continue
        
        # Filter by name if specified
        if name:
            platform_tokens = [t for t in platform_tokens if t["name"] == name]
            if not platform_tokens:
                console.print(f"No token found with name '{name}' for {plat}", style="yellow")
                continue
        
        table = Table(title=f"{plat} Tokens")
        table.add_column("Name")
        table.add_column("Scopes")
        table.add_column("Created")
        table.add_column("Expires")
        if show_values:
            table.add_column("Token Value")
        
        for token in platform_tokens:
            row = [
                token["name"],
                ", ".join(token.get("scopes", [])),
                token.get("created_at", "Unknown"),
                token.get("expires_at", "Never")
            ]
            
            if show_values:
                row.append(token["token"])
            
            table.add_row(*row)
        
        console.print(table)


def main():
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(description="View stored Git tokens")
    parser.add_argument("--platform", choices=["github", "gitlab", "bitbucket"], 
                      help="Filter tokens by platform")
    parser.add_argument("--name", help="Filter tokens by name")
    parser.add_argument("--show-values", action="store_true", 
                      help="Show token values (sensitive information)")
    
    args = parser.parse_args()
    
    tokens = load_tokens()
    
    if not tokens:
        console.print("No tokens found.", style="yellow")
        return
    
    display_tokens(tokens, args.platform, args.show_values, args.name)


if __name__ == "__main__":
    main()
