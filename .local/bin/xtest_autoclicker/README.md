# XTest Window Autoclicker

A tool that clicks within specific application windows **without moving your physical mouse cursor**, allowing you to continue working normally while the autoclicker operates independently.

## Features

- Sends synthetic mouse events that don't affect your physical cursor
- Select a specific window for automation
- Define multiple click positions within the window
- Set custom click intervals
- Add random jitter to clicks for more natural behavior
- Limit the total number of clicks
- Option to enable/disable window activation

## How It Works

This tool uses the X11 XTest extension to send synthetic mouse events directly to X11 windows. Unlike traditional autoclickers that take over your physical mouse, this tool:

1. Uses XTest to send "virtual" mouse events to the target window
2. Leaves your physical mouse cursor free for you to use normally
3. Works even when the target window isn't in focus (in most cases)

## Requirements

- Linux with X11 (not Wayland)
- Python 3.6+
- xdotool (for window selection and geometry)
- Python-xlib (for XTest events)

## Installation

1. Install xdotool:
```bash
sudo apt-get install xdotool
```

2. Install Python dependencies:
```bash
pip install python-xlib
```

3. Make the script executable:
```bash
chmod +x xtest_autoclicker.py
```

## Usage

### Basic Usage

Run the script:
```bash
./xtest_autoclicker.py
```

This will start the interactive setup wizard:
1. Click on the window you want to automate (after 3-second delay)
2. Add click positions by moving your cursor and pressing Enter
3. Start the autoclicker

### Command Line Options

```bash
./xtest_autoclicker.py --interval 0.5 --jitter 5 --clicks 100
```

Options:
- `--interval`: Time between clicks in seconds (default: 1.0)
- `--jitter`: Random jitter in pixels for more natural clicks (default: 0)
- `--clicks`: Maximum number of clicks before stopping (default: unlimited)
- `--window-name`: Select window by name instead of clicking on it
- `--no-activate`: Don't activate window before clicking (may not work for all applications)

### During Operation

- Press Ctrl+C to stop the autoclicker

## Troubleshooting

Common issues:

1. **Clicks not registering**: Some applications may require window activation. If clicks aren't registering, try running without the `--no-activate` option.

2. **Window selection issues**: If selecting a window by clicking doesn't work, try using the `--window-name` option instead.

3. **XTest not working**: If you're using Wayland instead of X11, this tool won't work as XTest is an X11 extension. Check your display server with `echo $XDG_SESSION_TYPE`.

4. **Permission errors**: If you see X11 permission errors, try running `xhost +local:` to temporarily allow local connections to X server.

## Technical Details

The XTest extension provides a way to generate input events without actually moving the input devices. This allows programs to:

- Generate synthetic mouse and keyboard events
- Perform automated testing of GUI applications 
- Create automation tools that don't disturb the user

This is much different from PyAutoGUI or similar libraries that move the physical cursor.