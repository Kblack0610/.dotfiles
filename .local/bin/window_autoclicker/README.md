# Window Autoclicker

A lightweight tool to automate mouse clicks within a specific application window without disturbing your work elsewhere.

## Features

- Select a specific window for automation
- Define multiple click positions within the window
- Set custom click intervals
- Add random jitter to clicks for more natural behavior
- Limit the total number of clicks
- Clicks stay within the target window even as you work elsewhere

## Requirements

- Python 3.6+
- xdotool (Linux)
- Python packages: pyautogui, python-xlib

## Installation

1. Install xdotool:
```bash
sudo apt-get install xdotool
```

2. Install Python dependencies:
```bash
pip install pyautogui python-xlib
```

3. Make the script executable:
```bash
chmod +x window_autoclicker.py
```

## Usage

### Basic Usage

Simply run the script:
```bash
./window_autoclicker.py
```

This will start the interactive setup wizard:
1. Click on the window you want to automate (after 3-second delay)
2. Add click positions by moving your cursor and pressing Enter
3. Start the autoclicker

### Command Line Options

```bash
./window_autoclicker.py --interval 0.5 --jitter 5 --clicks 100
```

- `--interval`: Time between clicks in seconds (default: 1.0)
- `--jitter`: Random jitter in pixels for more natural clicks (default: 0)
- `--clicks`: Maximum number of clicks before stopping (default: unlimited)

### During Operation

- Press Ctrl+C to stop the autoclicker

## How It Works

This tool uses xdotool to identify and interact with specific windows in the X Window System. It:

1. Captures a target window's ID and geometry
2. Records relative click positions within that window
3. Activates the window before each click
4. Restores focus after clicking
5. Continues this process until stopped manually or reaching click limit

## Troubleshooting

If you encounter issues:

1. Ensure xdotool is installed properly
2. Verify you have the required Python packages
3. Some applications may have window properties that make them difficult to detect
4. Window managers like i3, Openbox, or tiling window managers may require additional configuration