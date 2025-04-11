#!/usr/bin/env python3
# chmod +x window_autoclicker.py
"""
Window Autoclicker - A tool to automatically click within a specific window

This script allows you to select a window and set up automatic clicking
patterns within that window without disturbing your work elsewhere.
"""

import argparse
import time
import sys
import subprocess
import random
from typing import Tuple, Optional, List

try:
    import pyautogui
    import Xlib
    from Xlib import display, X
    from Xlib.ext import xtest
except ImportError:
    print("Required dependencies not found. Installing...")
    subprocess.call([sys.executable, "-m", "pip", "install", "pyautogui", "python-xlib"])
    import pyautogui
    import Xlib
    from Xlib import display, X
    from Xlib.ext import xtest

# Disable PyAutoGUI's failsafe
pyautogui.FAILSAFE = False

class WindowAutoclicker:
    def __init__(self):
        self.display = display.Display()
        self.screen = self.display.screen()
        self.root = self.screen.root
        self.selected_window = None
        self.is_running = False
        self.click_interval = 1.0  # Default: 1 second between clicks
        self.jitter = 0  # Default: No jitter
        self.click_count = 0
        self.max_clicks = None  # Default: No limit
        self.click_positions = []  # List of positions to click

    def select_window(self):
        """Prompt user to click on a window to select it"""
        print("Click on the window you want to automate (you have 3 seconds)...")
        time.sleep(3)
        
        # Get the current mouse position
        x, y = pyautogui.position()
        
        # Find the window at this position
        window_id = self.get_window_at_position(x, y)
        
        if window_id:
            self.selected_window = window_id
            window_name = self.get_window_name(window_id)
            print(f"Selected window: {window_name} (id: {window_id})")
            
            # Get window geometry
            geometry = self.get_window_geometry(window_id)
            if geometry:
                print(f"Window geometry: x={geometry[0]}, y={geometry[1]}, width={geometry[2]}, height={geometry[3]}")
                return True
            
        print("Failed to select window. Please try again.")
        return False

    def get_window_at_position(self, x: int, y: int) -> Optional[int]:
        """Get the window ID at the given position"""
        result = subprocess.run(["xdotool", "mousemove", str(x), str(y), "getmouselocation", "--shell"], 
                               capture_output=True, text=True)
        if result.returncode == 0:
            output = result.stdout
            for line in output.splitlines():
                if line.startswith("WINDOW="):
                    try:
                        return int(line.split("=")[1])
                    except ValueError:
                        pass
        return None

    def get_window_name(self, window_id: int) -> str:
        """Get the window name from its ID"""
        result = subprocess.run(["xdotool", "getwindowname", str(window_id)], 
                               capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
        return "Unknown"

    def get_window_geometry(self, window_id: int) -> Optional[Tuple[int, int, int, int]]:
        """Get the geometry (position and size) of a window"""
        result = subprocess.run(["xdotool", "getwindowgeometry", "--shell", str(window_id)], 
                               capture_output=True, text=True)
        if result.returncode == 0:
            try:
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
            except (ValueError, IndexError):
                pass
        return None

    def add_click_position(self, relative_x: int, relative_y: int):
        """Add a position (relative to window) to click"""
        self.click_positions.append((relative_x, relative_y))
        print(f"Added click position: ({relative_x}, {relative_y})")

    def capture_click_position(self):
        """Capture the current mouse position to add as a click position"""
        if not self.selected_window:
            print("No window selected. Please select a window first.")
            return
        
        print("Move your mouse to the position you want to click and press Enter...")
        input()
        
        x, y = pyautogui.position()
        window_geometry = self.get_window_geometry(self.selected_window)
        
        if window_geometry:
            window_x, window_y, _, _ = window_geometry
            relative_x = x - window_x
            relative_y = y - window_y
            self.add_click_position(relative_x, relative_y)
        else:
            print("Could not get window geometry.")

    def click_at_position(self, window_id: int, rel_x: int, rel_y: int):
        """Click at a specific position relative to window"""
        geometry = self.get_window_geometry(window_id)
        if not geometry:
            print(f"Could not get geometry for window {window_id}")
            return

        window_x, window_y, _, _ = geometry
        
        # Apply optional jitter
        if self.jitter > 0:
            jitter_x = random.randint(-self.jitter, self.jitter)
            jitter_y = random.randint(-self.jitter, self.jitter)
            target_x = window_x + rel_x + jitter_x
            target_y = window_y + rel_y + jitter_y
        else:
            target_x = window_x + rel_x
            target_y = window_y + rel_y
            
        # Ensure window is active
        subprocess.run(["xdotool", "windowactivate", "--sync", str(window_id)])
        
        # Move mouse and click
        pyautogui.moveTo(target_x, target_y)
        pyautogui.click()
        
        self.click_count += 1
        
        # Print status
        if self.max_clicks:
            print(f"Click {self.click_count}/{self.max_clicks} at ({rel_x}, {rel_y})")
        else:
            print(f"Click {self.click_count} at ({rel_x}, {rel_y})")

    def start_clicking(self):
        """Start the autoclicker"""
        if not self.selected_window:
            print("No window selected. Please select a window first.")
            return
            
        if not self.click_positions:
            print("No click positions defined. Please add at least one position.")
            return
            
        print(f"Starting autoclicker (interval: {self.click_interval}s, jitter: {self.jitter}px)")
        print("Press Ctrl+C to stop")
        
        self.is_running = True
        self.click_count = 0
        
        try:
            position_index = 0
            while self.is_running:
                # Check if we've reached the maximum number of clicks
                if self.max_clicks and self.click_count >= self.max_clicks:
                    print(f"Reached maximum number of clicks ({self.max_clicks})")
                    break
                    
                # Get next position to click
                rel_x, rel_y = self.click_positions[position_index]
                
                # Click at this position
                self.click_at_position(self.selected_window, rel_x, rel_y)
                
                # Move to next position (cycling through the list)
                position_index = (position_index + 1) % len(self.click_positions)
                
                # Wait for next click
                time.sleep(self.click_interval)
                
        except KeyboardInterrupt:
            print("\nStopping autoclicker")
            self.is_running = False

def main():
    parser = argparse.ArgumentParser(description="Automate clicking in a specific window")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="Time between clicks in seconds (default: 1.0)")
    parser.add_argument("--jitter", type=int, default=0,
                        help="Random jitter in pixels (default: 0)")
    parser.add_argument("--clicks", type=int,
                        help="Maximum number of clicks (default: unlimited)")
    
    args = parser.parse_args()
    
    try:
        # Check if xdotool is installed
        subprocess.run(["xdotool", "--version"], 
                      capture_output=True, check=True)
    except (subprocess.SubprocessError, FileNotFoundError):
        print("Error: xdotool is required but not found. Please install it:")
        print("  sudo apt-get install xdotool")
        return
    
    clicker = WindowAutoclicker()
    clicker.click_interval = args.interval
    clicker.jitter = args.jitter
    clicker.max_clicks = args.clicks
    
    # Setup wizard
    print("Window Autoclicker")
    print("-----------------")
    
    # Step 1: Select window
    if not clicker.select_window():
        return
        
    # Step 2: Add click positions
    while True:
        print("\nClick positions:")
        for i, (x, y) in enumerate(clicker.click_positions):
            print(f"  {i+1}. ({x}, {y})")
            
        print("\nOptions:")
        print("  1. Add a click position")
        print("  2. Start clicking")
        print("  3. Exit")
        
        choice = input("Choose an option (1-3): ")
        
        if choice == "1":
            clicker.capture_click_position()
        elif choice == "2":
            if clicker.click_positions:
                clicker.start_clicking()
            else:
                print("Please add at least one click position first.")
        elif choice == "3":
            break
        else:
            print("Invalid choice. Please try again.")

if __name__ == "__main__":
    main()