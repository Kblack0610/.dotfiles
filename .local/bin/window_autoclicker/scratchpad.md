# Window Autoclicker Project

## Task Overview
Create a lightweight alternative to VMs for automating mouse clicks within a specific application window without disturbing work in other windows.

## Progress
[X] Create project structure in .dotfiles/.local/bin/window_autoclicker
[X] Create main Python script (window_autoclicker.py)
[X] Create README with instructions
[X] Create installation script (install.sh)
[X] Add necessary permissions comments

## Technical Approach
- Using xdotool for window detection and management
- PyAutoGUI for mouse control
- Python-Xlib for X11 window interaction
- Interactive setup wizard for ease of use
- Command-line arguments for customization

## Lessons
- Need xdotool for X11 window management on Linux
- PyAutoGUI can be used for mouse automation
- Python-Xlib provides direct access to X Window System
- xdotool can identify window IDs and manage window focus
- Window positions need to be tracked relative to window coordinates

## Next Steps (for the user)
1. Make the scripts executable: 
   ```
   chmod +x window_autoclicker.py install.sh
   ```
2. Run the installation script:
   ```
   ./install.sh
   ```
3. Run the autoclicker:
   ```
   ./window_autoclicker.py
   ```