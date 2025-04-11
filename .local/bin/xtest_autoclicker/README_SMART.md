# Smart XTest Autoclicker

An advanced automation tool that can search for and interact with UI elements in applications without moving your physical cursor. 

## Key Features

- **Text Recognition**: Find and click on text elements automatically
- **Template Matching**: Find buttons and UI elements using image templates
- **Intelligent Automation**: Chain actions together in sequence
- **Zero Cursor Movement**: Uses X11 XTest extension to keep your cursor free
- **Configuration Files**: Save and load automation sequences
- **Interactive Setup**: Create automation sequences without coding

## How It Works

The Smart Autoclicker uses:

1. **OCR (Optical Character Recognition)** via Tesseract to identify text on the screen
2. **Computer Vision** via OpenCV to find buttons and UI elements
3. **X11 XTest Extension** to send synthetic mouse events without moving your cursor

## Requirements

- Linux with X11 (not Wayland)
- Python 3.6+
- xdotool
- Tesseract OCR engine
- Python packages: python-xlib, pillow, pytesseract, opencv-python, numpy

## Installation

1. Install system dependencies:
```bash
sudo apt-get install xdotool tesseract-ocr
```

2. Install Python dependencies:
```bash
pip install python-xlib pillow pytesseract opencv-python numpy
```

3. Make the script executable:
```bash
chmod +x smart_autoclicker.py
```

## Usage

### Interactive Mode

Run without arguments to use the interactive setup:
```bash
./smart_autoclicker.py
```

This will guide you through:
1. Selecting a target window
2. Creating a sequence of actions
3. Running the automation

### Configuration File

Create and save a configuration file in interactive mode, then load it:
```bash
./smart_autoclicker.py --config my_automation.json
```

### Command Line Options

```bash
./smart_autoclicker.py --window-name "Application Title" --debug
```

Options:
- `--config`: Path to a configuration file
- `--window-name`: Select window by name instead of clicking
- `--debug`: Show detailed debugging information
- `--no-activate`: Don't activate window before actions (may not work for all applications)

## Creating Actions

The Smart Autoclicker supports these action types:

### 1. Click on Text

Finds text anywhere in the window and clicks it:
```json
{
  "type": "click_text",
  "text": "Submit",
  "required": true
}
```

### 2. Click on Image Template

Finds and clicks UI elements using template matching:
```json
{
  "type": "click_template",
  "template": "/path/to/button_image.png",
  "threshold": 0.8,
  "required": false
}
```

### 3. Click at Position

Clicks at a specific position relative to the window:
```json
{
  "type": "click_position",
  "x": 100,
  "y": 200,
  "required": true
}
```

### 4. Type Text

Types a string of text:
```json
{
  "type": "type_text",
  "text": "Hello world",
  "required": false
}
```

### 5. Wait

Pause before the next action:
```json
{
  "type": "wait",
  "duration": 2.5,
  "required": false
}
```

## Tips for Text Recognition

- Text recognition works best with clear, high-contrast text
- Increase success rates by using unique text patterns
- You may need to adjust window scaling if text is too small

## Tips for Template Matching

- Use small, distinctive areas for templates rather than large ones
- Adjust the threshold if you're getting false positives/negatives
- Templates must exactly match what appears on screen (consider color, scaling, etc.)

## Troubleshooting

1. **OCR Not Working**: Ensure Tesseract is properly installed
2. **Templates Not Matching**: Try using smaller, more specific templates
3. **Actions Fail**: Try increasing the retry count in the configuration
4. **Keypresses Not Working**: Some applications may block synthetic input