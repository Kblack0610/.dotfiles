#!/bin/bash
# chmod +x install.sh
# Installation script for Window Autoclicker

echo "Installing Window Autoclicker..."

# Make script executable
chmod +x window_autoclicker.py

# Check if xdotool is installed
if ! command -v xdotool &> /dev/null; then
    echo "xdotool not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y xdotool
else
    echo "xdotool already installed."
fi

# Install Python dependencies
echo "Installing Python dependencies..."
pip install --user pyautogui python-xlib

# Create symlink in path (optional)
read -p "Create symlink to window_autoclicker.py in ~/.local/bin? (y/n): " create_symlink
if [[ $create_symlink == "y" ]]; then
    mkdir -p ~/.local/bin
    ln -sf "$(pwd)/window_autoclicker.py" ~/.local/bin/window-autoclicker
    echo "Symlink created. You can now run 'window-autoclicker' from anywhere."
    echo "Make sure ~/.local/bin is in your PATH."
fi

echo "Installation complete!"
echo "Run './window_autoclicker.py' to start the autoclicker."