#!/usr/bin/env python3
"""
Git Token Generator - A tool to programmatically generate tokens for various Git platforms.
"""

import os
import sys
import json
import argparse
import getpass
import logging
from pathlib import Path
from typing import Dict, List, Optional, Any
from datetime import datetime, timedelta

import requests
import yaml
from rich.console import Console
from rich.table import Table
from rich.logging import RichHandler
from dotenv import load_dotenv
from cryptography.fernet import Fernet

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    datefmt="[%X]",
    handlers=[RichHandler(rich_tracebacks=True)]
)
logger = logging.getLogger("git_token_generator")
console = Console()

# Token storage configuration
CONFIG_DIR = Path.home() / ".config" / "git-token-generator"
TOKENS_FILE = CONFIG_DIR / "tokens.json"
KEY_FILE = CONFIG_DIR / "key.key"

# Ensure configuration directory exists
CONFIG_DIR.mkdir(parents=True, exist_ok=True)


class TokenManager:
    """Manages secure storage and retrieval of tokens."""
    
    def __init__(self):
        """Initialize the token manager."""
        self._ensure_key_exists()
        self._load_tokens()
    
    def _ensure_key_exists(self) -> None:
        """Ensure encryption key exists, create if it doesn't."""
        if not KEY_FILE.exists():
            key = Fernet.generate_key()
            with open(KEY_FILE, "wb") as key_file:
                key_file.write(key)
            # Set restrictive permissions
            os.chmod(KEY_FILE, 0o600)
    
    def _get_key(self) -> bytes:
        """Get the encryption key."""
        with open(KEY_FILE, "rb") as key_file:
            return key_file.read()
    
    def _get_cipher(self) -> Fernet:
        """Get the cipher for encryption/decryption."""
        return Fernet(self._get_key())
    
    def _load_tokens(self) -> None:
        """Load tokens from storage."""
        self.tokens = {}
        if TOKENS_FILE.exists():
            try:
                with open(TOKENS_FILE, "r") as f:
                    encrypted_data = json.load(f)
                    
                cipher = self._get_cipher()
                for platform, entries in encrypted_data.items():
                    self.tokens[platform] = []
                    for entry in entries:
                        decrypted_token = cipher.decrypt(entry["token"].encode()).decode()
                        entry["token"] = decrypted_token
                        self.tokens[platform].append(entry)
            except Exception as e:
                logger.error(f"Error loading tokens: {e}")
                self.tokens = {}
    
    def save_token(self, platform: str, token: str, name: str, scopes: List[str], 
                  expires_at: Optional[str] = None) -> None:
        """Save a token securely."""
        if platform not in self.tokens:
            self.tokens[platform] = []
        
        # Encrypt the token
        cipher = self._get_cipher()
        encrypted_token = cipher.encrypt(token.encode()).decode()
        
        token_data = {
            "name": name,
            "token": token,  # Store unencrypted in memory
            "encrypted_token": encrypted_token,
            "scopes": scopes,
            "created_at": datetime.now().isoformat(),
            "expires_at": expires_at
        }
        
        self.tokens[platform].append(token_data)
        self._save_tokens()
        
    def _save_tokens(self) -> None:
        """Save tokens to disk."""
        # Convert to format for saving (with encrypted tokens)
        save_data = {}
        for platform, entries in self.tokens.items():
            save_data[platform] = []
            for entry in entries:
                save_entry = entry.copy()
                save_entry["token"] = entry["encrypted_token"]
                del save_entry["encrypted_token"]
                save_data[platform].append(save_entry)
        
        with open(TOKENS_FILE, "w") as f:
            json.dump(save_data, f, indent=2)
        
        # Set restrictive permissions
        os.chmod(TOKENS_FILE, 0o600)
    
    def list_tokens(self, platform: Optional[str] = None) -> Dict[str, List[Dict[str, Any]]]:
        """List all tokens or tokens for a specific platform."""
        if platform:
            return {platform: self.tokens.get(platform, [])}
        return self.tokens
    
    def get_token(self, platform: str, name: str) -> Optional[str]:
        """Get a specific token by platform and name."""
        if platform not in self.tokens:
            return None
        
        for entry in self.tokens[platform]:
            if entry["name"] == name:
                return entry["token"]
        return None


class GitHubTokenGenerator:
    """Generate GitHub personal access tokens."""
    
    BASE_URL = "https://api.github.com"
    
    def __init__(self, username: Optional[str] = None, password: Optional[str] = None):
        """Initialize with GitHub credentials."""
        self.username = username
        self.password = password
    
    def _authenticate(self) -> None:
        """Authenticate with GitHub."""
        if not self.username:
            self.username = input("GitHub Username: ")
        
        if not self.password:
            self.password = getpass.getpass("GitHub Password: ")
    
    def generate_token(self, name: str, scopes: List[str], expiration: int = 30) -> str:
        """
        Generate a new GitHub personal access token.
        
        Args:
            name: Name of the token
            scopes: List of permission scopes
            expiration: Days until expiration (0 for no expiration)
            
        Returns:
            The generated token
        """
        self._authenticate()
        
        expiration_date = None
        if expiration > 0:
            expiration_date = (datetime.now() + timedelta(days=expiration)).strftime("%Y-%m-%d")
        
        # Create the authorization
        headers = {"Accept": "application/vnd.github+json"}
        auth = (self.username, self.password)
        data = {
            "note": name,
            "scopes": scopes
        }
        
        if expiration_date:
            data["expires_at"] = expiration_date
        
        # Note: This method requires basic authentication, which GitHub is gradually phasing out
        # For production use, consider GitHub's web application flow for OAuth Apps
        response = requests.post(
            f"{self.BASE_URL}/authorizations",
            headers=headers,
            auth=auth,
            json=data
        )
        
        if response.status_code == 201:
            result = response.json()
            logger.info(f"Successfully created GitHub token: {name}")
            return result["token"]
        else:
            logger.error(f"Failed to create GitHub token: {response.text}")
            raise Exception(f"GitHub token creation failed: {response.status_code} - {response.text}")
            
    def list_scopes(self) -> List[str]:
        """List available GitHub token scopes."""
        return [
            "repo", "repo:status", "repo_deployment", "public_repo", "repo:invite", 
            "security_events", "admin:repo_hook", "write:repo_hook", "read:repo_hook",
            "admin:org", "write:org", "read:org", "admin:public_key", "write:public_key",
            "read:public_key", "admin:org_hook", "gist", "notifications", "user", 
            "read:user", "user:email", "user:follow", "delete_repo", "write:discussion",
            "read:discussion", "admin:gpg_key", "write:gpg_key", "read:gpg_key",
            "workflow", "packages", "admin:packages", "write:packages", "read:packages"
        ]


class GitLabTokenGenerator:
    """Generate GitLab personal access tokens."""
    
    def __init__(self, base_url: str = "https://gitlab.com", access_token: Optional[str] = None):
        """Initialize with GitLab instance URL and optional token for auth."""
        self.base_url = base_url
        self.access_token = access_token
    
    def _authenticate(self) -> None:
        """Authenticate with GitLab."""
        if not self.access_token:
            self.access_token = getpass.getpass("GitLab Access Token for authentication: ")
    
    def generate_token(self, name: str, scopes: List[str], expiration: int = 30) -> str:
        """
        Generate a new GitLab personal access token.
        
        Args:
            name: Name of the token
            scopes: List of permission scopes
            expiration: Days until expiration (0 for no expiration)
            
        Returns:
            The generated token
        """
        self._authenticate()
        
        expiration_date = None
        if expiration > 0:
            expiration_date = (datetime.now() + timedelta(days=expiration)).strftime("%Y-%m-%d")
        
        headers = {"PRIVATE-TOKEN": self.access_token}
        data = {
            "name": name,
            "scopes": scopes
        }
        
        if expiration_date:
            data["expires_at"] = expiration_date
        
        response = requests.post(
            f"{self.base_url}/api/v4/personal_access_tokens",
            headers=headers,
            json=data
        )
        
        if response.status_code == 201:
            result = response.json()
            logger.info(f"Successfully created GitLab token: {name}")
            return result["token"]
        else:
            logger.error(f"Failed to create GitLab token: {response.text}")
            raise Exception(f"GitLab token creation failed: {response.status_code} - {response.text}")
    
    def list_scopes(self) -> List[str]:
        """List available GitLab token scopes."""
        return [
            "api", "read_user", "read_api", "read_repository", "write_repository",
            "read_registry", "write_registry", "sudo"
        ]


class BitbucketTokenGenerator:
    """Generate Bitbucket access tokens."""
    
    BASE_URL = "https://bitbucket.org/site/oauth2/access_token"
    
    def __init__(self, username: Optional[str] = None, password: Optional[str] = None,
                client_id: Optional[str] = None, client_secret: Optional[str] = None):
        """Initialize with Bitbucket credentials or OAuth app credentials."""
        self.username = username
        self.password = password
        self.client_id = client_id
        self.client_secret = client_secret
    
    def _authenticate(self) -> None:
        """Authenticate with Bitbucket."""
        # If using client credentials (OAuth app)
        if not self.client_id:
            self.client_id = input("Bitbucket OAuth Client ID: ")
        
        if not self.client_secret:
            self.client_secret = getpass.getpass("Bitbucket OAuth Client Secret: ")
        
        # If using username/password
        if not self.client_id and not self.client_secret:
            if not self.username:
                self.username = input("Bitbucket Username: ")
            
            if not self.password:
                self.password = getpass.getpass("Bitbucket Password: ")
    
    def generate_token(self, name: str, scopes: List[str], expiration: int = 30) -> str:
        """
        Generate a new Bitbucket access token using OAuth.
        
        Args:
            name: Name of the token (for reference only)
            scopes: List of permission scopes
            expiration: Days until expiration (not directly supported by Bitbucket)
            
        Returns:
            The generated token
        """
        self._authenticate()
        
        # Bitbucket uses OAuth2 for token generation
        auth = None
        data = {"grant_type": "client_credentials"}
        
        if self.client_id and self.client_secret:
            auth = (self.client_id, self.client_secret)
        else:
            auth = (self.username, self.password)
            data["grant_type"] = "password"
        
        if scopes:
            data["scope"] = " ".join(scopes)
        
        response = requests.post(
            self.BASE_URL,
            auth=auth,
            data=data
        )
        
        if response.status_code == 200:
            result = response.json()
            logger.info(f"Successfully created Bitbucket token: {name}")
            # We store the access token, not the refresh token
            return result["access_token"]
        else:
            logger.error(f"Failed to create Bitbucket token: {response.text}")
            raise Exception(f"Bitbucket token creation failed: {response.status_code} - {response.text}")
    
    def list_scopes(self) -> List[str]:
        """List available Bitbucket token scopes."""
        return [
            "account", "account:write", "team", "team:write", "repository", 
            "repository:write", "repository:admin", "pullrequest", "pullrequest:write",
            "snippet", "snippet:write", "issue", "issue:write", "wiki", "wiki:write", 
            "webhook", "webhook:write", "project", "project:write"
        ]


def display_tokens(tokens: Dict[str, List[Dict[str, Any]]]) -> None:
    """Display tokens in a formatted table."""
    for platform, platform_tokens in tokens.items():
        if not platform_tokens:
            console.print(f"No tokens found for {platform}")
            continue
            
        table = Table(title=f"{platform} Tokens")
        table.add_column("Name")
        table.add_column("Scopes")
        table.add_column("Created")
        table.add_column("Expires")
        
        for token in platform_tokens:
            scopes = ", ".join(token.get("scopes", []))
            created = token.get("created_at", "Unknown")
            expires = token.get("expires_at", "Never")
            
            table.add_row(token["name"], scopes, created, expires)
        
        console.print(table)


def main():
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(description="Generate tokens for Git platforms")
    subparsers = parser.add_subparsers(dest="command", help="Command to run")
    
    # Generate command
    gen_parser = subparsers.add_parser("generate", help="Generate a new token")
    gen_parser.add_argument("platform", choices=["github", "gitlab", "bitbucket"], 
                           help="Git platform to generate token for")
    gen_parser.add_argument("--name", required=True, help="Name for the token")
    gen_parser.add_argument("--scopes", nargs="+", help="Scopes for the token")
    gen_parser.add_argument("--expiration", type=int, default=30, 
                           help="Days until token expires (0 for no expiration)")
    gen_parser.add_argument("--username", help="Username for authentication")
    gen_parser.add_argument("--password", help="Password for authentication")
    gen_parser.add_argument("--client-id", help="OAuth client ID (Bitbucket)")
    gen_parser.add_argument("--client-secret", help="OAuth client secret (Bitbucket)")
    gen_parser.add_argument("--base-url", help="Base URL for GitLab instance")
    gen_parser.add_argument("--access-token", help="Access token for authentication (GitLab)")
    
    # List command
    list_parser = subparsers.add_parser("list", help="List existing tokens")
    list_parser.add_argument("--platform", choices=["github", "gitlab", "bitbucket"], 
                            help="Filter tokens by platform")
    
    # List scopes command
    scopes_parser = subparsers.add_parser("list-scopes", help="List available token scopes")
    scopes_parser.add_argument("platform", choices=["github", "gitlab", "bitbucket"], 
                              help="Platform to list scopes for")
    
    args = parser.parse_args()
    
    # Load environment variables from .env file if it exists
    load_dotenv()
    
    # Initialize token manager
    token_manager = TokenManager()
    
    if args.command == "generate":
        try:
            if args.platform == "github":
                generator = GitHubTokenGenerator(args.username, args.password)
                
                # If no scopes provided, use some sensible defaults
                scopes = args.scopes or ["repo", "read:user", "user:email"]
                
                token = generator.generate_token(args.name, scopes, args.expiration)
                token_manager.save_token(
                    "github", 
                    token, 
                    args.name, 
                    scopes,
                    (datetime.now() + timedelta(days=args.expiration)).isoformat() if args.expiration else None
                )
                console.print(f"Generated GitHub token: {token}", style="green")
                
            elif args.platform == "gitlab":
                base_url = args.base_url or "https://gitlab.com"
                generator = GitLabTokenGenerator(base_url, args.access_token)
                
                # If no scopes provided, use some sensible defaults
                scopes = args.scopes or ["api", "read_repository"]
                
                token = generator.generate_token(args.name, scopes, args.expiration)
                token_manager.save_token(
                    "gitlab", 
                    token, 
                    args.name, 
                    scopes,
                    (datetime.now() + timedelta(days=args.expiration)).isoformat() if args.expiration else None
                )
                console.print(f"Generated GitLab token: {token}", style="green")
                
            elif args.platform == "bitbucket":
                generator = BitbucketTokenGenerator(
                    args.username, 
                    args.password,
                    args.client_id,
                    args.client_secret
                )
                
                # If no scopes provided, use some sensible defaults
                scopes = args.scopes or ["repository", "pullrequest"]
                
                token = generator.generate_token(args.name, scopes, args.expiration)
                token_manager.save_token(
                    "bitbucket", 
                    token, 
                    args.name, 
                    scopes,
                    (datetime.now() + timedelta(days=args.expiration)).isoformat() if args.expiration else None
                )
                console.print(f"Generated Bitbucket token: {token}", style="green")
                
        except Exception as e:
            logger.error(f"Error generating token: {e}")
            sys.exit(1)
            
    elif args.command == "list":
        tokens = token_manager.list_tokens(args.platform)
        display_tokens(tokens)
        
    elif args.command == "list-scopes":
        if args.platform == "github":
            generator = GitHubTokenGenerator()
            scopes = generator.list_scopes()
        elif args.platform == "gitlab":
            generator = GitLabTokenGenerator()
            scopes = generator.list_scopes()
        elif args.platform == "bitbucket":
            generator = BitbucketTokenGenerator()
            scopes = generator.list_scopes()
            
        console.print(f"Available scopes for {args.platform}:")
        for scope in scopes:
            console.print(f"  - {scope}")
    
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
