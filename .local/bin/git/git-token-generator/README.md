# Git Token Generator

A Python script to programmatically generate personal access tokens for various Git platforms (GitHub, GitLab, Bitbucket).

## Features

- Generate personal access tokens for GitHub, GitLab, and Bitbucket
- Store tokens securely with encryption
- List stored tokens
- View token details with option to show sensitive values
- Delete tokens selectively or all at once
- View available token scopes for each platform

## Installation

1. Clone the repository
2. Install dependencies:

```bash
pip install -r requirements.txt
```

## Usage

Make the scripts executable:

```bash
chmod +x git_token_generator.py view_tokens.py delete_tokens.py
```

### Generate a token

```bash
# GitHub token
./git_token_generator.py generate github --name "MyGitHubToken" --scopes repo read:user user:email

# GitLab token
./git_token_generator.py generate gitlab --name "MyGitLabToken" --scopes api read_repository

# Bitbucket token
./git_token_generator.py generate bitbucket --name "MyBitbucketToken" --scopes repository pullrequest
```

### View stored tokens

```bash
# View all tokens (using the main script)
./git_token_generator.py list

# Using the dedicated view script
./view_tokens.py

# Filter by platform
./view_tokens.py --platform github

# Filter by name
./view_tokens.py --name "MyGitHubToken"

# Display token values (sensitive information)
./view_tokens.py --show-values
```

### Delete tokens

```bash
# Delete tokens for a platform
./delete_tokens.py --platform github

# Delete a specific token by name
./delete_tokens.py --name "MyGitHubToken"

# Force deletion without confirmation
./delete_tokens.py --platform github --force

# Delete all tokens (requires force and confirmation)
./delete_tokens.py --all --force
```

### List available scopes

```bash
# List GitHub scopes
./git_token_generator.py list-scopes github

# List GitLab scopes
./git_token_generator.py list-scopes gitlab

# List Bitbucket scopes
./git_token_generator.py list-scopes bitbucket
```

## Token Storage

Tokens are stored securely in `~/.config/git-token-generator/tokens.json` and encrypted with a key stored in `~/.config/git-token-generator/key.key`.

## Authentication

Different platforms require different authentication methods:

- GitHub: Username and password
- GitLab: Existing access token for authentication
- Bitbucket: Username/password or OAuth client credentials

## Security Notes

- Your credentials are never stored, only used for API authentication
- Generated tokens are encrypted before being saved to disk
- File permissions are set to be accessible only by the owner (0600)
