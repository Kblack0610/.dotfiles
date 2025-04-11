#!/bin/bash
# Installation script for XTest Window Autoclicker

echo "Installing XTest Window Autoclicker..."

# Make script executable
chmod +x xtest_autoclicker.py

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
pip install --user python-xlib

# Check if running X11 (XTest won't work on Wayland)
if [ "$XDG_SESSION_TYPE" = "wayland" ]; then
    echo "WARNING: You are running Wayland, not X11."
    echo "XTest extension only works with X11. This autoclicker may not function correctly."
fi

# Create symlink in path (optional)
read -p "Create symlink to xtest_autoclicker.py in ~/.local/bin? (y/n): " create_symlink
if [[ $create_symlink == "y" ]]; then
    mkdir -p ~/.local/bin
    ln -sf "$(pwd)/xtest_autoclicker.py" ~/.local/bin/xtest-autoclicker
    echo "Symlink created. You can now run 'xtest-autoclicker' from anywhere."
    echo "Make sure ~/.local/bin is in your PATH."
fi

echo "Installation complete!"
echo "Run './xtest_autoclicker.py' to start the autoclicker."