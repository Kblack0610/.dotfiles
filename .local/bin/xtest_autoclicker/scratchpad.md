# XTest Window Autoclicker Project

## Task Overview
Create a window autoclicker that uses X11's XTest extension to send synthetic mouse events without taking over the physical cursor, allowing the user to continue working normally.

## Progress
[X] Create project structure in .dotfiles/.local/bin/xtest_autoclicker
[X] Create main Python script (xtest_autoclicker.py)
[X] Create README with instructions
[X] Create installation script (install.sh)
[X] Add scratchpad to track progress and lessons

## Technical Approach
- Using X11's XTest extension for synthetic mouse events
- xdotool for window detection and management
- Python-Xlib for X11 interaction
- Interactive setup wizard for ease of use
- Command-line arguments for customization

## Lessons
- The XTest extension allows sending synthetic mouse events without moving the physical cursor
- XTest is specific to X11 and won't work on Wayland
- Window activation may be needed for some applications to properly receive the clicks
- Python-Xlib provides direct access to XTest functionality
- Window positions need to be tracked relative to window coordinates
- Some applications may have security measures that prevent synthetic input

## Next Steps (for the user)
1. Make the scripts executable: 
   ```
   chmod +x xtest_autoclicker.py install.sh
   ```
2. Run the installation script:
   ```
   ./install.sh
   ```
3. Run the autoclicker:
   ```
   ./xtest_autoclicker.py
   ```

## Testing Notes
- Some applications may require window activation to receive clicks properly
- If clicks aren't registering, try running without the --no-activate flag
- Applications can behave differently with synthetic vs. real mouse events