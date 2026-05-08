#!/usr/bin/env bash

# Arch-on-WSL Installation Script
# Run directly after cloning the repo:
#   ~/.dotfiles/.local/src/installation_scripts/linux/install_wsl.sh
#
# Intentionally minimal: CLI floor + dev tools (node/python/docker/postgres),
# zsh/oh-my-zsh/starship, dotfiles via stow with a WSL-tailored ignore list.
# No GUI/desktop/streaming/printing/keyd — those belong on the Windows host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

source "$BASE_DIR/base_functions.sh"
load_config

# Minimal ArchWSL ships as root with no sudo. Make `sudo` a no-op when we're
# already root; require it (and bail clearly) when we aren't.
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    if ! command -v sudo >/dev/null 2>&1; then
        log_error "Not running as root and sudo isn't installed. Either run this as root or install sudo first."
        exit 1
    fi
    SUDO="sudo"
fi

install_pacman_package() {
    local package="$1"

    if pacman -Q "$package" &>/dev/null; then
        log_info "$package already installed"
        return 0
    fi

    log_info "Installing $package..."
    if $SUDO pacman -S --noconfirm "$package" &>/dev/null; then
        log_info "✓ $package installed"
    else
        log_warning "✗ Failed to install $package"
    fi
}

update_system() {
    log_section "Updating system packages"
    if ! $SUDO pacman -Syu --noconfirm; then
        log_error "pacman -Syu failed. Common WSL fixes:"
        log_error "  sudo pacman-key --init && sudo pacman-key --populate archlinux"
        log_error "  sudo rm -f /var/lib/pacman/db.lck   # if a previous run was killed"
        log_error "  sudo pacman -Sy archlinux-keyring   # if keyring is stale"
        return 1
    fi
    log_info "System updated"
}

install_packages() {
    log_section "Installing WSL packages"
    install_package_list install_pacman_package arch $PACKAGES_WSL
}

install_zsh() {
    log_section "Setting Zsh as default shell"

    local zsh_path
    zsh_path="$(command -v zsh)"
    if [[ -z "$zsh_path" ]]; then
        log_error "zsh not in PATH — install_packages must run first"
        return 1
    fi

    if [[ "$SHELL" == *zsh ]]; then
        log_info "Zsh is already the default shell"
        return 0
    fi

    if chsh -s "$zsh_path"; then
        log_info "✓ Default shell changed to zsh (restart terminal to apply)"
    else
        log_warning "chsh failed — run: sudo chsh -s $zsh_path $USER"
    fi
}

# Docker on WSL needs systemd — write /etc/wsl.conf and warn the user that
# `wsl --shutdown` from Windows is required for it to take effect.
setup_docker() {
    log_section "Setting up Docker"

    if ! command -v docker &>/dev/null; then
        log_warning "docker not found — install_packages should have installed it. Skipping."
        return 0
    fi

    if [[ ! -f /etc/wsl.conf ]] || ! grep -q '^systemd=true' /etc/wsl.conf; then
        log_info "Enabling systemd in /etc/wsl.conf"
        $SUDO tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
        log_warning "From Windows PowerShell run: wsl --shutdown   (then reopen this distro)"
    fi

    if ! getent group docker >/dev/null; then
        $SUDO groupadd docker
    fi
    if ! id -nG "$USER" | grep -qw docker; then
        $SUDO usermod -aG docker "$USER"
        log_info "Added $USER to docker group (re-login or \`newgrp docker\`)"
    fi

    if pidof systemd &>/dev/null; then
        $SUDO systemctl enable --now docker || log_warning "systemctl enable docker failed"
    else
        log_warning "systemd not active yet — Docker will start after \`wsl --shutdown\`"
    fi
}

# initdb the cluster but don't auto-start the service. The user runs postgres
# on demand via `sudo systemctl start postgresql` once systemd is active.
setup_postgres() {
    log_section "Setting up PostgreSQL"

    if ! command -v postgres &>/dev/null; then
        log_warning "postgres not found — skipping initdb"
        return 0
    fi

    local data_dir="/var/lib/postgres/data"
    if [[ -f "$data_dir/PG_VERSION" ]]; then
        log_info "PostgreSQL data dir already initialized"
    else
        log_info "Initializing PostgreSQL data dir at $data_dir"
        if [[ $EUID -eq 0 ]]; then
            runuser -u postgres -- initdb --locale=C.UTF-8 --encoding=UTF8 -D "$data_dir" &>/dev/null \
                && log_info "✓ initdb complete" \
                || log_warning "initdb failed — run manually as the postgres user"
        else
            sudo -iu postgres initdb --locale=C.UTF-8 --encoding=UTF8 -D "$data_dir" &>/dev/null \
                && log_info "✓ initdb complete" \
                || log_warning "initdb failed — run manually as the postgres user"
        fi
    fi

    log_info "Start with: sudo systemctl start postgresql"
}

# WSL-tailored stow ignore: drop everything that's GUI, desktop-only, or
# host-OS-specific. Mirrors apply_dotfiles in base_functions but with WSL's
# subset of ignores.
apply_dotfiles() {
    log_section "Applying dotfiles"

    if ! command -v stow &>/dev/null; then
        log_warning "stow not installed, skipping dotfiles"
        return 0
    fi

    cd ~/.dotfiles

    [[ -f ~/.bashrc && ! -L ~/.bashrc ]] && mv -n ~/.bashrc ~/.bashrc.preinstall.bak
    [[ -f ~/.zshrc  && ! -L ~/.zshrc  ]] && mv -n ~/.zshrc  ~/.zshrc.preinstall.bak

    mkdir -p ~/.config

    cat > .stow-local-ignore <<'EOF'
^/\.git$
^/\.gitignore$
^/\.gitmodules$
^/\.github$
^/AGENTS\.md$
^/README\.md$
^/\.local/src/installation_scripts$
^/\.fonts$
^/\.config/hypr$
^/\.config/waybar$
^/\.config/wofi$
^/\.config/kitty$
^/\.config/keyd$
^/\.config/karabiner$
^/\.config/aerospace$
^/\.config/launchd$
^/\.config/brewfile$
^/\.config/spicetify$
^/\.config/firefox$
^/\.config/Code$
^/\.config/Windsurf$
^/\.config/vnc$
^/\.config/cups$
^/\.config/unity3d$
^/\.config/zoomus\.conf$
^/\.config/profile$
^/\.config/windows$
EOF

    stow .

    git config core.hooksPath .githooks
    log_info "Git hooks configured"

    log_info "Dotfiles applied"
}

# Notes-sync — personal Forgejo + MQTT/ntfy fan-out. No-op when
# NOTES_PRIMARY_REMOTE_URL isn't set.
setup_notes_sync() {
    if [[ -z "${NOTES_PRIMARY_REMOTE_URL:-}" ]]; then
        log_warning "NOTES_PRIMARY_REMOTE_URL not set — skipping notes-bootstrap"
        return 0
    fi

    local bootstrap="$HOME/.dotfiles/.local/bin/notes-bootstrap"
    if [[ ! -x "$bootstrap" ]]; then
        log_warning "notes-bootstrap not found at $bootstrap — skipping"
        return 0
    fi

    log_section "Setting up notes sync"
    "$bootstrap" --primary-url "$NOTES_PRIMARY_REMOTE_URL" \
                 ${NOTES_BACKUP_REMOTE_URL:+--backup-url "$NOTES_BACKUP_REMOTE_URL"}
}

install_all() {
    create_directories
    update_system
    install_packages

    install_zsh
    install_oh_my_zsh
    install_starship

    install_rust

    setup_docker
    setup_postgres

    setup_git
    install_npm_packages
    apply_dotfiles
    setup_ai_memory

    setup_notes_sync

    log_section "Installation Complete!"
    log_info "Restart your terminal or run: source ~/.zshrc"
    log_warning "From Windows PowerShell run: wsl --shutdown   (to apply systemd in /etc/wsl.conf)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_all
fi
