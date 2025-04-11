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
                        window_id_str = line.split("=")[1]
                        # Handle both decimal and hex formats
                        if window_id_str.startswith("0x"):
                            window_id = int(window_id_str, 16)
                        else:
                            window_id = int(window_id_str)
                        break
                    except (ValueError, IndexError):
                        pass
            
            if window_id:
                self.selected_window = window_id
                window_name = self.get_window_name(window_id)
                print(f"Selected window: {window_name} (id: {window_id:x})")
                
                # Try different methods to get window geometry for i3
                geometry_methods = [
                    self.get_window_geometry,
                    self.get_window_geometry_alternative
                ]
                
                for method in geometry_methods:
                    self.window_geometry = method(window_id)
                    if self.window_geometry:
                        x, y, width, height = self.window_geometry
                        print(f"Window geometry: x={x}, y={y}, width={width}, height={height}")
                        return True
                
                # If we couldn't get the geometry, try a fallback method
                print("Warning: Could not determine window geometry using standard methods.")
                print("Attempting fallback method for i3 window manager...")
                
                # For i3, we can try to get the active window size
                self.window_geometry = self.get_i3_window_geometry(window_id)
                if self.window_geometry:
                    x, y, width, height = self.window_geometry
                    print(f"Window geometry (i3 fallback): x={x}, y={y}, width={width}, height={height}")
                    return True
                    
                # Last resort: ask user for manual confirmation
                print("Could not automatically determine window geometry.")
                confirm = input("Do you want to continue anyway? This may affect click accuracy. (y/n): ")
                if confirm.lower() == 'y':
                    # Use screen dimensions as fallback
                    screen = self.display.screen()
                    self.window_geometry = (0, 0, screen.width_in_pixels, screen.height_in_pixels)
                    print(f"Using screen dimensions as fallback: {self.window_geometry}")
                    return True
        except subprocess.SubprocessError as e:
            print(f"Error running xdotool: {e}")
            
        print("Failed to select window. Please try again.")
        return False
        
    def get_window_geometry_alternative(self, window_id):
        """Alternative method to get window geometry, useful for i3 and other tiling WMs"""
        try:
            # Try using xwininfo
            result = subprocess.run(["xwininfo", "-id", str(window_id)], 
                                 capture_output=True, text=True, check=True)
            
            x, y, width, height = None, None, None, None
            for line in result.stdout.splitlines():
                if "Absolute upper-left X:" in line:
                    x = int(line.split(":")[-1].strip())
                elif "Absolute upper-left Y:" in line:
                    y = int(line.split(":")[-1].strip())
                elif "Width:" in line:
                    width = int(line.split(":")[-1].strip())
                elif "Height:" in line:
                    height = int(line.split(":")[-1].strip())
            
            if all(v is not None for v in [x, y, width, height]):
                return (x, y, width, height)
        except (subprocess.SubprocessError, ValueError, IndexError) as e:
            print(f"Alternative geometry method failed: {e}")
            
        return None
    
    def get_i3_window_geometry(self, window_id):
        """Get window geometry specifically for i3 window manager"""
        try:
            # Try using i3-msg to get window position
            result = subprocess.run(["i3-msg", "-t", "get_tree"], 
                                 capture_output=True, text=True, check=True)
            
            import json
            tree = json.loads(result.stdout)
            
            # Function to recursively search for window
            def find_window(node, target_id):
                if node.get('window') == target_id:
                    rect = node.get('rect', {})
                    return (rect.get('x', 0), rect.get('y', 0), 
                            rect.get('width', 0), rect.get('height', 0))
                
                for child in node.get('nodes', []) + node.get('floating_nodes', []):
                    result = find_window(child, target_id)
                    if result:
                        return result
                return None
            
            # Search for window in i3 tree
            geometry = find_window(tree, window_id)
            if geometry and all(v > 0 for v in geometry[2:]):
                return geometry
            
        except (subprocess.SubprocessError, json.JSONDecodeError) as e:
            print(f"i3 geometry method failed: {e}")
            
        return None
        
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
    
    def preprocess_image(self, image, preprocess_type="default"):
        """Apply various preprocessing techniques to improve OCR accuracy"""
        # Convert PIL image to OpenCV format
        img = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        
        if preprocess_type == "default":
            # Basic preprocessing (grayscale)
            return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        
        elif preprocess_type == "threshold":
            # Basic thresholding
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
            return cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY | cv2.THRESH_OTSU)[1]
        
        elif preprocess_type == "adaptive":
            # Adaptive thresholding
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
            return cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, 
                                        cv2.THRESH_BINARY, 11, 2)
        
        elif preprocess_type == "contrast":
            # Increase contrast
            lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
            l, a, b = cv2.split(lab)
            clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
            cl = clahe.apply(l)
            limg = cv2.merge((cl, a, b))
            return cv2.cvtColor(limg, cv2.COLOR_LAB2BGR)
        
        return img
        
    def find_text_in_screenshot(self, target_text, screenshot=None):
        """Find text in the window screenshot and return its coordinates"""
        if screenshot is None:
            screenshot = self.capture_window_screenshot()
            if screenshot is None:
                return None
        
        try:
            # Save original image for tesseract processing
            temp_file = "/tmp/smart_autoclicker_temp.png"
            screenshot.save(temp_file)
            
            # Try different preprocessing techniques to improve OCR
            preprocessing_methods = ["default", "threshold", "adaptive", "contrast"]
            all_ocr_data = {}
            
            for method in preprocessing_methods:
                # Preprocess image
                processed_img = self.preprocess_image(screenshot, method)
                
                # Save processed image for debugging
                processed_file = f"/tmp/smart_autoclicker_{method}.png"
                cv2.imwrite(processed_file, processed_img)
                
                # Perform OCR with positioning data
                try:
                    if method == "default":
                        # For default, use original image
                        ocr_data = pytesseract.image_to_data(screenshot, output_type=pytesseract.Output.DICT)
                    else:
                        ocr_data = pytesseract.image_to_data(processed_img, output_type=pytesseract.Output.DICT)
                    
                    all_ocr_data[method] = ocr_data
                    print(f"\nProcessing using {method} preprocessing:")
                except Exception as e:
                    print(f"Error with {method} preprocessing: {e}")
                    continue
            
            # Combine results from all preprocessing methods
            print("\n--- All text found in window ---")
            print(f"Target text: '{target_text}'")
            print(f"Attempted preprocessing methods: {', '.join(all_ocr_data.keys())}")
            print("\nText found with different preprocessing methods:")
            
            # Print results from each method
            found_any_text = False
            all_found_text = set()
            
            for method, ocr_data in all_ocr_data.items():
                non_empty_text = [text for i, text in enumerate(ocr_data['text']) if text.strip()]
                if non_empty_text:
                    found_any_text = True
                    print(f"\n[Method: {method}]")
                    for i, text in enumerate(ocr_data['text']):
                        if text.strip():  # Only show non-empty text
                            conf = ocr_data['conf'][i]
                            x = ocr_data['left'][i]
                            y = ocr_data['top'][i]
                            all_found_text.add(text.strip())
                            print(f"  Text: '{text}' (confidence: {conf}) at ({x}, {y})")
            
            if not found_any_text:
                print("No text found with any preprocessing method!")
                print("Possible issues:")
                print("  - Text may be too small or low contrast")
                print("  - Window might be obscured or minimized")
                print("  - OCR settings may need adjustment")
            else:
                print("\nAll unique text found (across all methods):")
                for text in sorted(all_found_text):
                    print(f"  '{text}'")
            
            print("--- End of found text ---\n")
            
            # Convert target text to lowercase for case-insensitive matching
            target_text = target_text.lower()
            target_parts = target_text.split()
            print(f"Searching for: '{target_text}' (parts: {target_parts})")
            
            # Try without preprocessing first with additional OCR config
            try:
                # Add a custom OCR config specifically for hyperlinks and special formatting
                custom_config = r'--oem 3 --psm 11 -c preserve_interword_spaces=1'
                hyperlink_ocr = pytesseract.image_to_data(
                    screenshot, 
                    output_type=pytesseract.Output.DICT,
                    config=custom_config
                )
                
                print("\nAdditional OCR pass with custom config for hyperlinks:")
                for i, text in enumerate(hyperlink_ocr['text']):
                    if text.strip():  # Only show non-empty text
                        conf = hyperlink_ocr['conf'][i]
                        print(f"  Text: '{text}' (confidence: {conf})")
                        
                        # Direct check for hyperlink text
                        if target_text.lower() in text.lower():
                            x = hyperlink_ocr['left'][i]
                            y = hyperlink_ocr['top'][i]
                            w = hyperlink_ocr['width'][i] if hyperlink_ocr['width'][i] > 0 else 50
                            h = hyperlink_ocr['height'][i] if hyperlink_ocr['height'][i] > 0 else 20
                            center_x = x + w // 2
                            center_y = y + h // 2
                            print(f"Found hyperlink text match: '{text}' at position ({center_x}, {center_y})")
                            return (center_x, center_y)
                            
                all_ocr_data['hyperlink'] = hyperlink_ocr
            except Exception as e:
                print(f"Error with hyperlink OCR: {e}")
            
            # Try each preprocessing method to find the text
            for method_name, ocr_data in all_ocr_data.items():
                print(f"\nSearching in {method_name} results:")
                
                # Try exact match first
                for i, text in enumerate(ocr_data['text']):
                    if not text.strip():
                        continue
                    
                    # Try exact match
                    text_lower = text.lower()
                    if target_text in text_lower:
                        # Get coordinates from OCR data
                        x = ocr_data['left'][i]
                        y = ocr_data['top'][i]
                        w = ocr_data['width'][i] if ocr_data['width'][i] > 0 else 50  # Fallback width
                        h = ocr_data['height'][i] if ocr_data['height'][i] > 0 else 20  # Fallback height
                        
                        # Calculate center of the text
                        center_x = x + w // 2
                        center_y = y + h // 2
                        
                        print(f"Found exact match with {method_name}: '{text}' at position ({center_x}, {center_y})")
                        return (center_x, center_y)
                
                # Track best fuzzy match for this method
                best_match = None
                best_ratio = 0.7  # Minimum threshold for fuzzy match
                best_i = -1
                
                # If exact match fails, try partial matching
                for i, text in enumerate(ocr_data['text']):
                    if not text.strip():
                        continue
                        
                    text_lower = text.lower()
                    
                    # Check for partial matches (any word in target appears in text)
                    matching_parts = [part for part in target_parts if part in text_lower]
                    if matching_parts:
                        match_ratio = len(matching_parts) / len(target_parts)
                        print(f"Partial match: '{text}' contains {len(matching_parts)}/{len(target_parts)} target words")
                        
                        if match_ratio > best_ratio:
                            best_ratio = match_ratio
                            best_match = text
                            best_i = i
                
                if best_match:
                    # Get coordinates from OCR data
                    x = ocr_data['left'][best_i]
                    y = ocr_data['top'][best_i]
                    w = ocr_data['width'][best_i] if ocr_data['width'][best_i] > 0 else 50
                    h = ocr_data['height'][best_i] if ocr_data['height'][best_i] > 0 else 20
                    
                    # Calculate center of the text
                    center_x = x + w // 2
                    center_y = y + h // 2
                    
                    print(f"Found best fuzzy match with {method_name}: '{best_match}' (score: {best_ratio:.2f}) at position ({center_x}, {center_y})")
                    return (center_x, center_y)
            
            # If all methods failed, look for any text containing part of the target
            print("\nNo good match found with any method. Looking for any partial matches...")
            
            # Combine results from all methods
            all_candidates = []
            for method_name, ocr_data in all_ocr_data.items():
                for i, text in enumerate(ocr_data['text']):
                    if not text.strip():
                        continue
                    
                    text_lower = text.lower()
                    for part in target_parts:
                        if len(part) > 3 and part in text_lower:  # Only match on meaningful parts
                            x = ocr_data['left'][i]
                            y = ocr_data['top'][i]
                            w = ocr_data['width'][i] if ocr_data['width'][i] > 0 else 50
                            h = ocr_data['height'][i] if ocr_data['height'][i] > 0 else 20
                            center_x = x + w // 2
                            center_y = y + h // 2
                            
                            candidate = {
                                'text': text,
                                'part': part,
                                'method': method_name,
                                'x': center_x,
                                'y': center_y
                            }
                            all_candidates.append(candidate)
            
            if all_candidates:
                # Pick the first candidate
                best_candidate = all_candidates[0]
                print(f"Using fallback: Found '{best_candidate['text']}' containing '{best_candidate['part']}'")
                print(f"Position: ({best_candidate['x']}, {best_candidate['y']}), Method: {best_candidate['method']}")
                return (best_candidate['x'], best_candidate['y'])
            
            print(f"Text '{target_text}' not found in window (neither exact nor fuzzy match)")
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

def list_all_windows():
    """List all available windows with their IDs"""
    try:
        # Get all window IDs
        result = subprocess.run(["xdotool", "search", "--onlyvisible", "--all"], 
                             capture_output=True, text=True, check=True)
        window_ids = result.stdout.strip().split('\n')
        
        print("Available windows:")
        print("-" * 80)
        print(f"{'Window ID':<12} | {'Window Name':<50} | {'Geometry':>15}")
        print("-" * 80)
        
        for wid in window_ids:
            if not wid:
                continue
                
            try:
                # Get window name
                name_result = subprocess.run(["xdotool", "getwindowname", wid], 
                                          capture_output=True, text=True, check=True)
                window_name = name_result.stdout.strip()
                
                # Get window geometry
                geo_result = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid], 
                                         capture_output=True, text=True, check=True)
                
                # Parse geometry
                width, height = "?", "?"
                for line in geo_result.stdout.splitlines():
                    if line.startswith("WIDTH="):
                        width = line.split("=")[1]
                    elif line.startswith("HEIGHT="):
                        height = line.split("=")[1]
                        
                geometry = f"{width}x{height}"
                print(f"{wid:<12} | {window_name[:50]:<50} | {geometry:>15}")
            except subprocess.SubprocessError:
                print(f"{wid:<12} | <unable to get window info>")
                
        print("-" * 80)
        print("\nTo use a specific window, run with: --window-id <WINDOW_ID>")
        return True
    except subprocess.SubprocessError as e:
        print(f"Error listing windows: {e}")
        return False

def select_window_by_id(window_id):
    """Validate and select a window by its ID"""
    try:
        # Verify the window exists
        subprocess.run(["xdotool", "getwindowname", window_id], 
                     capture_output=True, text=True, check=True)
        
        # Convert to int (might be hex or decimal)
        if window_id.startswith("0x"):
            return int(window_id, 16)
        else:
            return int(window_id)
    except (subprocess.SubprocessError, ValueError) as e:
        print(f"Error selecting window {window_id}: {e}")
        return None

def main():
    parser = argparse.ArgumentParser(description="Smart XTest Autoclicker - find and click UI elements without moving your cursor")
    parser.add_argument("--config", type=str, help="Path to configuration file")
    parser.add_argument("--window-name", type=str, help="Select window by name instead of clicking on it")
    parser.add_argument("--window-id", type=str, help="Directly specify window ID (useful for i3 and other tiling managers)")
    parser.add_argument("--list-windows", action="store_true", help="List all available windows with their IDs")
    parser.add_argument("--debug", action="store_true", help="Enable debug mode")
    parser.add_argument("--no-activate", action="store_true", help="Don't activate the window before clicking")
    parser.add_argument("--test-click", action="store_true", help="Perform a test click to verify XTest functionality")
    parser.add_argument("--i3", action="store_true", help="Use i3-specific window handling methods")
    
    args = parser.parse_args()
    
    try:
        # Check if xdotool is installed
        subprocess.run(["xdotool", "--version"], capture_output=True, check=True)
    except (subprocess.SubprocessError, FileNotFoundError):
        print("Error: xdotool is required but not found. Please install it:")
        print("  sudo apt-get install xdotool")
        return 1
    
    # List windows and exit if requested
    if args.list_windows:
        list_all_windows()
        return 0
    
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
    
    # Priority: window-id > window-name > interactive selection
    if args.window_id:
        window_id = select_window_by_id(args.window_id)
        if window_id:
            clicker.selected_window = window_id
            clicker.window_geometry = clicker.get_window_geometry(window_id) or \
                                     clicker.get_window_geometry_alternative(window_id) or \
                                     clicker.get_i3_window_geometry(window_id)
            if clicker.window_geometry:
                window_name = clicker.get_window_name(window_id)
                print(f"Selected window: {window_name} (id: {window_id:x})")
                x, y, width, height = clicker.window_geometry
                print(f"Window geometry: x={x}, y={y}, width={width}, height={height}")
                window_selected = True
            else:
                print(f"Warning: Could not get geometry for window ID {args.window_id}")
                if input("Continue without geometry? (y/n): ").lower() == 'y':
                    # Use screen dimensions as fallback
                    screen = clicker.display.screen()
                    clicker.window_geometry = (0, 0, screen.width_in_pixels, screen.height_in_pixels)
                    print(f"Using screen dimensions as fallback: {clicker.window_geometry}")
                    window_selected = True
    elif args.window_name:        
        window_selected = clicker.select_window_by_name(args.window_name)
    
    # Handle i3 window manager specifics
    if args.i3:
        print("Using i3 window manager specific methods")
        # Prioritize i3 geometry methods
        clicker.get_window_geometry = clicker.get_i3_window_geometry
    
    # Run a test click if requested
    if args.test_click and window_selected:
        print("\nPerforming test click...")
        test_x, test_y = 100, 100  # Default position relative to window
        
        if clicker.window_geometry:
            window_x, window_y, _, _ = clicker.window_geometry
            abs_x = window_x + test_x
            abs_y = window_y + test_y
            
            print(f"Clicking at position ({test_x}, {test_y}) relative to window")
            print(f"Absolute screen position: ({abs_x}, {abs_y})")
            
            if clicker.send_click_event(abs_x, abs_y):
                print("Test click successful!")
                return 0
            else:
                print("Test click failed. XTest events may not be working correctly.")
                return 1
        else:
            print("Cannot perform test click without window geometry information.")
            return 1
    
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