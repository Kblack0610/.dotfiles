#!/usr/bin/env python3
"""
Smart XTest Autoclicker - Automatically find and click UI elements in windows

This enhanced version of the XTest autoclicker can:
1. Take screenshots of target windows
2. Recognize text and UI elements
3. Automatically click based on found elements
4. Execute keyboard actions
"""

import argparse
import time
import sys
import subprocess
import random
import os
import json
import re
from typing import Tuple, Optional, List, Dict, Any, Union

try:
    from Xlib import display, X
    from Xlib.ext import xtest
    import numpy as np
    from PIL import Image, ImageGrab
    import pytesseract
    import cv2
except ImportError:
    print("Required dependencies not found. Installing...")
    subprocess.call([sys.executable, "-m", "pip", "install", "python-xlib", "pillow", "pytesseract", "opencv-python", "numpy"])
    from Xlib import display, X
    from Xlib.ext import xtest
    import numpy as np
    from PIL import Image, ImageGrab
    import pytesseract
    import cv2

# Default Tesseract path - change if necessary
TESSERACT_CMD = 'tesseract'
try:
    pytesseract.pytesseract.tesseract_cmd = TESSERACT_CMD
except Exception:
    print(f"Warning: Could not set tesseract path to {TESSERACT_CMD}")
    print("If OCR fails, install tesseract or set the correct path.")

class SmartAutoclicker:
    def __init__(self):
        self.display = display.Display()
        self.root = self.display.screen().root
        self.selected_window = None
        self.window_geometry = None
        self.is_running = False
        self.click_interval = 1.0  # Default: 1 second between clicks
        self.actions = []  # List of automation actions
        self.current_screenshot = None
        self.debug_mode = False
        self.retry_count = 3  # Number of retries if element not found
        self.activate_window = True
        self.config_file = None
        
    def select_window_by_click(self):
        """Prompt user to click on a window to select it"""
        print("Click on the window you want to automate (you have 3 seconds)...")
        time.sleep(3)
        
        try:
            # Use xdotool to get the window ID under the cursor
            result = subprocess.run(["xdotool", "getmouselocation", "--shell"], 
                                  capture_output=True, text=True, check=True)
            
            window_id = None
            for line in result.stdout.splitlines():
                if line.startswith("WINDOW="):
                    try:
                        window_id = int(line.split("=")[1], 16)
                        break
                    except (ValueError, IndexError):
                        pass
            
            if window_id:
                self.selected_window = window_id
                window_name = self.get_window_name(window_id)
                print(f"Selected window: {window_name} (id: {window_id:x})")
                
                # Get window geometry
                self.window_geometry = self.get_window_geometry(window_id)
                if self.window_geometry:
                    x, y, width, height = self.window_geometry
                    print(f"Window geometry: x={x}, y={y}, width={width}, height={height}")
                    return True
        except subprocess.SubprocessError as e:
            print(f"Error running xdotool: {e}")
            
        print("Failed to select window. Please try again.")
        return False
        
    def select_window_by_name(self, window_name):
        """Select a window by its name/title"""
        try:
            result = subprocess.run(["xdotool", "search", "--name", window_name], 
                                  capture_output=True, text=True, check=True)
            
            if result.stdout.strip():
                window_ids = result.stdout.strip().split("\n")
                if window_ids:
                    window_id = int(window_ids[0])
                    self.selected_window = window_id
                    print(f"Selected window: {window_name} (id: {window_id:x})")
                    
                    # Get window geometry
                    self.window_geometry = self.get_window_geometry(window_id)
                    if self.window_geometry:
                        x, y, width, height = self.window_geometry
                        print(f"Window geometry: x={x}, y={y}, width={width}, height={height}")
                        return True
        except (subprocess.SubprocessError, ValueError) as e:
            print(f"Error selecting window by name: {e}")
            
        print(f"Failed to find window with name: {window_name}")
        return False
    
    def get_window_name(self, window_id):
        """Get the window name from its ID"""
        try:
            result = subprocess.run(["xdotool", "getwindowname", str(window_id)], 
                                  capture_output=True, text=True, check=True)
            return result.stdout.strip()
        except subprocess.SubprocessError:
            return "Unknown"
    
    def get_window_geometry(self, window_id):
        """Get the geometry (position and size) of a window"""
        try:
            result = subprocess.run(["xdotool", "getwindowgeometry", "--shell", str(window_id)], 
                                  capture_output=True, text=True, check=True)
            
            x, y, width, height = None, None, None, None
            for line in result.stdout.splitlines():
                if line.startswith("X="):
                    x = int(line.split("=")[1])
                elif line.startswith("Y="):
                    y = int(line.split("=")[1])
                elif line.startswith("WIDTH="):
                    width = int(line.split("=")[1])
                elif line.startswith("HEIGHT="):
                    height = int(line.split("=")[1])
            
            if all(v is not None for v in [x, y, width, height]):
                return (x, y, width, height)
        except (subprocess.SubprocessError, ValueError, IndexError):
            pass
            
        return None
    
    def send_click_event(self, x, y, button=1):
        """Send a synthetic click event using XTest at absolute coordinates"""
        try:
            # Move invisible cursor to target position
            xtest.fake_input(self.display, X.MotionNotify, x=x, y=y)
            
            # Simulate mouse down and up (click)
            xtest.fake_input(self.display, X.ButtonPress, button)
            xtest.fake_input(self.display, X.ButtonRelease, button)
            
            # Make sure events are processed
            self.display.sync()
            return True
        except Exception as e:
            print(f"Error sending XTest click event: {e}")
            return False
    
    def send_key_event(self, keycode):
        """Send a synthetic keyboard event using XTest"""
        try:
            # Key press and release
            xtest.fake_input(self.display, X.KeyPress, keycode)
            xtest.fake_input(self.display, X.KeyRelease, keycode)
            
            # Make sure events are processed
            self.display.sync()
            return True
        except Exception as e:
            print(f"Error sending XTest key event: {e}")
            return False
            
    def send_text(self, text):
        """Send a text string as keyboard events"""
        try:
            # Map from character to X11 keysym and keycode
            for char in text:
                # This is a simplification - a full implementation would need 
                # a complete mapping of characters to X11 keycodes
                if char.isalnum() or char in " ,.;'[]\\-=/`":
                    keysym = ord(char.lower())
                    keycode = self.display.keysym_to_keycode(keysym)
                    if keycode:
                        # Handle shift for uppercase letters
                        if char.isupper():
                            shift_keycode = self.display.keysym_to_keycode(50)  # 50 is Shift keysym
                            xtest.fake_input(self.display, X.KeyPress, shift_keycode)
                            xtest.fake_input(self.display, X.KeyPress, keycode)
                            xtest.fake_input(self.display, X.KeyRelease, keycode)
                            xtest.fake_input(self.display, X.KeyRelease, shift_keycode)
                        else:
                            xtest.fake_input(self.display, X.KeyPress, keycode)
                            xtest.fake_input(self.display, X.KeyRelease, keycode)
                        
                        # Make sure events are processed
                        self.display.sync()
                        time.sleep(0.01)  # Small delay between keypresses
            
            return True
        except Exception as e:
            print(f"Error sending text via XTest: {e}")
            return False
    
    def capture_window_screenshot(self):
        """Capture a screenshot of the selected window"""
        if not self.selected_window or not self.window_geometry:
            print("No window selected. Cannot take screenshot.")
            return None
        
        # Get window coordinates and dimensions
        x, y, width, height = self.window_geometry
        
        try:
            # Take screenshot
            screenshot = ImageGrab.grab(bbox=(x, y, x+width, y+height))
            return screenshot
        except Exception as e:
            print(f"Error capturing screenshot: {e}")
            return None
    
    def find_text_in_screenshot(self, target_text, screenshot=None):
        """Find text in the window screenshot and return its coordinates"""
        if screenshot is None:
            screenshot = self.capture_window_screenshot()
            if screenshot is None:
                return None
        
        try:
            # Save image for tesseract processing
            temp_file = "/tmp/smart_autoclicker_temp.png"
            screenshot.save(temp_file)
            
            # Perform OCR with positioning data
            ocr_data = pytesseract.image_to_data(screenshot, output_type=pytesseract.Output.DICT)
            
            # Search for the target text
            target_text = target_text.lower()
            for i, text in enumerate(ocr_data['text']):
                if target_text in text.lower():
                    # Get coordinates from OCR data
                    x = ocr_data['left'][i]
                    y = ocr_data['top'][i]
                    w = ocr_data['width'][i]
                    h = ocr_data['height'][i]
                    
                    # Calculate center of the text
                    center_x = x + w // 2
                    center_y = y + h // 2
                    
                    if self.debug_mode:
                        print(f"Found text '{text}' at position ({center_x}, {center_y})")
                    
                    return (center_x, center_y)
            
            if self.debug_mode:
                print(f"Text '{target_text}' not found in window")
            
            return None
        except Exception as e:
            print(f"Error finding text: {e}")
            return None
    
    def find_element_by_template(self, template_path, threshold=0.8, screenshot=None):
        """Find an element using template matching and return its coordinates"""
        if screenshot is None:
            screenshot = self.capture_window_screenshot()
            if screenshot is None:
                return None
        
        try:
            # Convert PIL image to OpenCV format
            screenshot_cv = cv2.cvtColor(np.array(screenshot), cv2.COLOR_RGB2BGR)
            
            # Read template image
            template = cv2.imread(template_path)
            if template is None:
                print(f"Error: Could not load template image from {template_path}")
                return None
            
            # Perform template matching
            result = cv2.matchTemplate(screenshot_cv, template, cv2.TM_CCOEFF_NORMED)
            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
            
            if max_val >= threshold:
                # Get template dimensions
                h, w = template.shape[:2]
                
                # Calculate center position
                center_x = max_loc[0] + w // 2
                center_y = max_loc[1] + h // 2
                
                if self.debug_mode:
                    print(f"Found template with {max_val:.2f} confidence at ({center_x}, {center_y})")
                
                return (center_x, center_y)
            
            if self.debug_mode:
                print(f"Template not found (best match: {max_val:.2f}, threshold: {threshold})")
            
            return None
        except Exception as e:
            print(f"Error finding template: {e}")
            return None
    
    def perform_action(self, action):
        """Perform a single automation action"""
        if not self.selected_window:
            print("No window selected. Cannot perform action.")
            return False
        
        # Ensure window geometry is up to date
        self.window_geometry = self.get_window_geometry(self.selected_window)
        if not self.window_geometry:
            print("Could not get window geometry. Cannot perform action.")
            return False
        
        # Activate window if needed
        if self.activate_window:
            try:
                subprocess.run(["xdotool", "windowactivate", "--sync", str(self.selected_window)], 
                             check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except subprocess.SubprocessError:
                print("Warning: Could not activate window")
        
        # Get action type and parameters
        action_type = action.get('type', '').lower()
        
        # Take a screenshot for element finding
        screenshot = self.capture_window_screenshot()
        self.current_screenshot = screenshot
        
        if action_type == 'click_text':
            # Find and click text
            text = action.get('text', '')
            if not text:
                print("Error: No text specified for click_text action")
                return False
            
            # Try to find the text
            for i in range(self.retry_count):
                coords = self.find_text_in_screenshot(text, screenshot)
                if coords:
                    window_x, window_y, _, _ = self.window_geometry
                    abs_x = window_x + coords[0]
                    abs_y = window_y + coords[1]
                    
                    print(f"Clicking on text '{text}' at position ({coords[0]}, {coords[1]})")
                    return self.send_click_event(abs_x, abs_y)
                
                if i < self.retry_count - 1:
                    print(f"Text '{text}' not found, retrying in 1 second...")
                    time.sleep(1)
                    screenshot = self.capture_window_screenshot()
            
            print(f"Error: Could not find text '{text}' after {self.retry_count} attempts")
            return False
        
        elif action_type == 'click_template':
            # Find and click template
            template = action.get('template', '')
            threshold = action.get('threshold', 0.8)
            
            if not template or not os.path.exists(template):
                print(f"Error: Template file '{template}' not found")
                return False
            
            # Try to find the template
            for i in range(self.retry_count):
                coords = self.find_element_by_template(template, threshold, screenshot)
                if coords:
                    window_x, window_y, _, _ = self.window_geometry
                    abs_x = window_x + coords[0]
                    abs_y = window_y + coords[1]
                    
                    print(f"Clicking on template '{template}' at position ({coords[0]}, {coords[1]})")
                    return self.send_click_event(abs_x, abs_y)
                
                if i < self.retry_count - 1:
                    print(f"Template '{template}' not found, retrying in 1 second...")
                    time.sleep(1)
                    screenshot = self.capture_window_screenshot()
            
            print(f"Error: Could not find template '{template}' after {self.retry_count} attempts")
            return False
        
        elif action_type == 'click_position':
            # Click at specific position
            x = action.get('x', 0)
            y = action.get('y', 0)
            
            window_x, window_y, _, _ = self.window_geometry
            abs_x = window_x + x
            abs_y = window_y + y
            
            print(f"Clicking at position ({x}, {y})")
            return self.send_click_event(abs_x, abs_y)
        
        elif action_type == 'type_text':
            # Type text
            text = action.get('text', '')
            if not text:
                print("Error: No text specified for type_text action")
                return False
            
            print(f"Typing text: '{text}'")
            return self.send_text(text)
        
        elif action_type == 'wait':
            # Wait for specified duration
            duration = action.get('duration', 1.0)
            print(f"Waiting for {duration} seconds")
            time.sleep(duration)
            return True
        
        else:
            print(f"Error: Unknown action type '{action_type}'")
            return False
    
    def run_automation(self):
        """Run the automation sequence"""
        if not self.selected_window:
            print("No window selected. Please select a window first.")
            return
            
        if not self.actions:
            print("No actions defined. Please add at least one action.")
            return
            
        print(f"Starting automation with {len(self.actions)} actions")
        print("Press Ctrl+C to stop")
        
        self.is_running = True
        action_index = 0
        
        try:
            while self.is_running:
                # Get next action to perform
                action = self.actions[action_index]
                
                # Perform the action
                success = self.perform_action(action)
                
                if not success and action.get('required', False):
                    print(f"Required action failed, stopping automation")
                    break
                
                # Move to next action (cycling through the list if loop is enabled)
                action_index = (action_index + 1) % len(self.actions)
                
                # Check if we've completed all actions and loop is disabled
                if action_index == 0 and not self.loop_actions:
                    print("Completed all actions")
                    break
                
                # Wait between actions
                time.sleep(self.click_interval)
                
        except KeyboardInterrupt:
            print("\nStopping automation")
            self.is_running = False
        finally:
            # Clean up X display connection
            self.display.close()
    
    def load_config(self, config_file):
        """Load automation configuration from JSON file"""
        try:
            with open(config_file, 'r') as f:
                config = json.load(f)
            
            # Set configuration parameters
            if 'interval' in config:
                self.click_interval = config['interval']
            
            if 'activate_window' in config:
                self.activate_window = config['activate_window']
            
            if 'retry_count' in config:
                self.retry_count = config['retry_count']
            
            if 'debug_mode' in config:
                self.debug_mode = config['debug_mode']
            
            if 'loop_actions' in config:
                self.loop_actions = config['loop_actions']
            else:
                self.loop_actions = True
            
            # Load actions
            if 'actions' in config and isinstance(config['actions'], list):
                self.actions = config['actions']
                print(f"Loaded {len(self.actions)} actions from configuration")
                return True
            else:
                print("Error: No actions found in configuration")
                return False
            
        except Exception as e:
            print(f"Error loading configuration: {e}")
            return False
    
    def save_config(self, config_file):
        """Save automation configuration to JSON file"""
        config = {
            'interval': self.click_interval,
            'activate_window': self.activate_window,
            'retry_count': self.retry_count,
            'debug_mode': self.debug_mode,
            'loop_actions': self.loop_actions,
            'actions': self.actions
        }
        
        try:
            with open(config_file, 'w') as f:
                json.dump(config, f, indent=2)
            print(f"Configuration saved to {config_file}")
            return True
        except Exception as e:
            print(f"Error saving configuration: {e}")
            return False
    
    def create_action_interactively(self):
        """Create an action interactively"""
        print("\nCreate New Action")
        print("-----------------")
        print("Action types:")
        print("1. Click on text")
        print("2. Click on image template")
        print("3. Click at specific position")
        print("4. Type text")
        print("5. Wait")
        
        choice = input("Choose action type (1-5): ")
        
        if choice == "1":
            # Click on text
            text = input("Enter text to find and click: ")
            action = {
                'type': 'click_text',
                'text': text,
                'required': input("Is this action required? (y/n): ").lower() == 'y'
            }
            
        elif choice == "2":
            # Click on template
            template = input("Enter path to template image: ")
            threshold = float(input("Enter matching threshold (0.0-1.0, default 0.8): ") or "0.8")
            action = {
                'type': 'click_template',
                'template': template,
                'threshold': threshold,
                'required': input("Is this action required? (y/n): ").lower() == 'y'
            }
            
        elif choice == "3":
            # Click at position
            print("Move your cursor to the desired position and press Enter...")
            input()
            
            # Get cursor position relative to window
            try:
                result = subprocess.run(["xdotool", "getmouselocation", "--shell"], 
                                      capture_output=True, text=True, check=True)
                
                mouse_x, mouse_y = None, None
                for line in result.stdout.splitlines():
                    if line.startswith("X="):
                        mouse_x = int(line.split("=")[1])
                    elif line.startswith("Y="):
                        mouse_y = int(line.split("=")[1])
                
                if mouse_x is not None and mouse_y is not None:
                    window_x, window_y, _, _ = self.window_geometry
                    rel_x = mouse_x - window_x
                    rel_y = mouse_y - window_y
                    
                    action = {
                        'type': 'click_position',
                        'x': rel_x,
                        'y': rel_y,
                        'required': input("Is this action required? (y/n): ").lower() == 'y'
                    }
                else:
                    print("Could not get mouse position.")
                    return None
            except subprocess.SubprocessError as e:
                print(f"Error getting mouse position: {e}")
                return None
            
        elif choice == "4":
            # Type text
            text = input("Enter text to type: ")
            action = {
                'type': 'type_text',
                'text': text,
                'required': input("Is this action required? (y/n): ").lower() == 'y'
            }
            
        elif choice == "5":
            # Wait
            duration = float(input("Enter wait duration in seconds: ") or "1.0")
            action = {
                'type': 'wait',
                'duration': duration,
                'required': False
            }
            
        else:
            print("Invalid choice")
            return None
        
        return action
    
    def interactive_setup(self):
        """Run interactive setup to create automation sequence"""
        # Set defaults
        self.loop_actions = True
        
        # Step 1: Select window
        window_selected = self.select_window_by_click()
        if not window_selected:
            return False
        
        # Step 2: Configure general settings
        print("\nGeneral Settings")
        print("---------------")
        
        self.click_interval = float(input("Enter time between actions in seconds (default 1.0): ") or "1.0")
        self.debug_mode = input("Enable debug mode? (y/n, default n): ").lower() == 'y'
        self.loop_actions = input("Loop actions? (y/n, default y): ").lower() != 'n'
        
        # Step 3: Create actions
        self.actions = []
        
        while True:
            print("\nCurrent Actions:")
            for i, action in enumerate(self.actions):
                action_type = action.get('type', 'unknown')
                if action_type == 'click_text':
                    print(f"  {i+1}. Click on text: '{action.get('text', '')}'")
                elif action_type == 'click_template':
                    print(f"  {i+1}. Click on template: '{action.get('template', '')}'")
                elif action_type == 'click_position':
                    print(f"  {i+1}. Click at position: ({action.get('x', 0)}, {action.get('y', 0)})")
                elif action_type == 'type_text':
                    print(f"  {i+1}. Type text: '{action.get('text', '')}'")
                elif action_type == 'wait':
                    print(f"  {i+1}. Wait for {action.get('duration', 1.0)} seconds")
            
            print("\nOptions:")
            print("  1. Add an action")
            print("  2. Remove an action")
            print("  3. Save configuration")
            print("  4. Load configuration")
            print("  5. Start automation")
            print("  6. Exit")
            
            choice = input("Choose an option (1-6): ")
            
            if choice == "1":
                action = self.create_action_interactively()
                if action:
                    self.actions.append(action)
                    print("Action added")
            elif choice == "2":
                if not self.actions:
                    print("No actions to remove")
                else:
                    index = int(input(f"Enter action number to remove (1-{len(self.actions)}): ")) - 1
                    if 0 <= index < len(self.actions):
                        del self.actions[index]
                        print("Action removed")
                    else:
                        print("Invalid action number")
            elif choice == "3":
                filename = input("Enter configuration filename: ")
                self.save_config(filename)
            elif choice == "4":
                filename = input("Enter configuration filename: ")
                if os.path.exists(filename):
                    self.load_config(filename)
                else:
                    print(f"File '{filename}' not found")
            elif choice == "5":
                if self.actions:
                    return True
                else:
                    print("Please add at least one action first")
            elif choice == "6":
                return False
            else:
                print("Invalid choice")
        
        return False

def main():
    parser = argparse.ArgumentParser(description="Smart XTest Autoclicker - find and click UI elements without moving your cursor")
    parser.add_argument("--config", type=str, help="Path to configuration file")
    parser.add_argument("--window-name", type=str, help="Select window by name instead of clicking on it")
    parser.add_argument("--debug", action="store_true", help="Enable debug mode")
    parser.add_argument("--no-activate", action="store_true", help="Don't activate the window before clicking")
    
    args = parser.parse_args()
    
    try:
        # Check if xdotool is installed
        subprocess.run(["xdotool", "--version"], capture_output=True, check=True)
    except (subprocess.SubprocessError, FileNotFoundError):
        print("Error: xdotool is required but not found. Please install it:")
        print("  sudo apt-get install xdotool")
        return 1
    
    try:
        # Check if tesseract is installed
        subprocess.run(["tesseract", "--version"], capture_output=True, check=True)
    except (subprocess.SubprocessError, FileNotFoundError):
        print("Warning: tesseract is not found. Text recognition will not work.")
        print("  Install it with: sudo apt-get install tesseract-ocr")
    
    clicker = SmartAutoclicker()
    clicker.debug_mode = args.debug
    clicker.activate_window = not args.no_activate
    
    # Setup window
    window_selected = False
    if args.window_name:
        window_selected = clicker.select_window_by_name(args.window_name)
    
    # Load configuration if specified
    if args.config:
        if os.path.exists(args.config):
            if clicker.load_config(args.config):
                if not window_selected:
                    # If window not selected by name, select it now
                    window_selected = clicker.select_window_by_click()
                
                if window_selected:
                    clicker.run_automation()
        else:
            print(f"Configuration file '{args.config}' not found")
    else:
        # Run interactive setup
        print("Smart XTest Autoclicker")
        print("----------------------")
        print("This tool can find and click UI elements without moving your cursor")
        
        if clicker.interactive_setup():
            clicker.run_automation()
    
    return 0

if __name__ == "__main__":
    sys.exit(main())