# XTest Window Autoclicker Project

## Task Overview
Create a window autoclicker that uses X11's XTest extension to send synthetic mouse events without taking over the physical cursor, allowing the user to continue working normally.

## Progress
[X] Create project structure in .dotfiles/.local/bin/xtest_autoclicker
[X] Create main Python script (xtest_autoclicker.py)
[X] Create README with instructions
[X] Create installation script (install.sh)
[X] Add scratchpad to track progress and lessons
[X] Create smart_autoclicker.py with element recognition capabilities
[X] Update script for compatibility with i3 window manager on Ubuntu

## Technical Approach
- Using X11's XTest extension for synthetic mouse events
- xdotool for window detection and management
- Python-Xlib for X11 interaction
- OCR (Tesseract) for text recognition in windows
- OpenCV for template matching to find UI elements
- Interactive setup wizard for ease of use
- Command-line arguments for customization

## Lessons
- The XTest extension allows sending synthetic mouse events without moving the physical cursor
- XTest is specific to X11 and won't work on Wayland
- Window activation may be needed for some applications to properly receive the clicks
- Python-Xlib provides direct access to XTest functionality
- Window positions need to be tracked relative to window coordinates
- Some applications may have security measures that prevent synthetic input
- Tiling window managers like i3 require special handling for window geometry
- Multiple window geometry detection methods are needed for reliable operation across different window managers
- Direct window ID selection is better than trying to click on windows in tiling managers
- Having a way to list all window IDs is crucial for finding the right window in complex setups

## Next Steps (for the user)
1. Make the scripts executable: 
   ```
   chmod +x xtest_autoclicker.py smart_autoclicker.py install.sh
   ```

2. For i3 window manager, first list all windows to find the ID of the target window:
   ```
   ./smart_autoclicker.py --list-windows
   ```

3. Then run the autoclicker with the specific window ID:
   ```
   ./smart_autoclicker.py --window-id <ID> --i3
   ```

4. Optional: Run a test click to verify functionality:
   ```
   ./smart_autoclicker.py --window-id <ID> --test-click
   ```

## Testing Notes
- Some applications may require window activation to receive clicks properly
- If clicks aren't registering, try running without the --no-activate flag
- Applications can behave differently with synthetic vs. real mouse events
- The --i3 flag helps with tiling window managers
- If window detection fails, use --window-id approach