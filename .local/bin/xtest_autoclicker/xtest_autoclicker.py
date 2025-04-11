#!/usr/bin/env python3
"""
XTest Window Autoclicker - A tool to click within a specific window without moving your cursor

This script uses the X11 XTest extension to send synthetic mouse events to a window
without taking over your physical mouse cursor, allowing you to continue working
while the autoclicker operates independently.
"""

import argparse
import time
import sys
import subprocess
import random
import os
from typing import Tuple, Optional, List

try:
    from Xlib import display, X
    from Xlib.ext import xtest
except ImportError:
    print("Required dependencies not found. Installing...")
    subprocess.call([sys.executable, "-m", "pip", "install", "python-xlib"])
    from Xlib import display, X
    from Xlib.ext import xtest

class XTestAutoclicker:
    def __init__(self):
        self.display = display.Display()
        self.root = self.display.screen().root
        self.selected_window = None
        self.window_geometry = None
        self.is_running = False
        self.click_interval = 1.0  # Default: 1 second between clicks
        self.jitter = 0  # Default: No jitter
        self.click_count = 0
        self.max_clicks = None  # Default: No limit
        self.click_positions = []  # List of positions to click
        
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
    
    def add_click_position(self, relative_x, relative_y):
        """Add a position (relative to window) to click"""
        self.click_positions.append((relative_x, relative_y))
        print(f"Added click position: ({relative_x}, {relative_y})")
    
    def capture_click_position(self):
        """Capture the current mouse position to add as a click position"""
        if not self.selected_window or not self.window_geometry:
            print("No window selected. Please select a window first.")
            return
        
        print("Move your mouse to the position you want to click and press Enter...")
        input()
        
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
                relative_x = mouse_x - window_x
                relative_y = mouse_y - window_y
                self.add_click_position(relative_x, relative_y)
            else:
                print("Could not get mouse position.")
        except subprocess.SubprocessError as e:
            print(f"Error getting mouse position: {e}")
    
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
    
    def click_at_window_position(self, window_id, rel_x, rel_y):
        """Click at a position relative to window using XTest (invisible to user)"""
        if not self.window_geometry:
            self.window_geometry = self.get_window_geometry(window_id)
            if not self.window_geometry:
                print(f"Could not get geometry for window {window_id:x}")
                return False
        
        window_x, window_y, _, _ = self.window_geometry
        
        # Apply optional jitter
        if self.jitter > 0:
            jitter_x = random.randint(-self.jitter, self.jitter)
            jitter_y = random.randint(-self.jitter, self.jitter)
            target_x = window_x + rel_x + jitter_x
            target_y = window_y + rel_y + jitter_y
        else:
            target_x = window_x + rel_x
            target_y = window_y + rel_y
        
        # Activate window (optional, but helps ensure clicks register properly)
        if self.activate_window:
            try:
                subprocess.run(["xdotool", "windowactivate", "--sync", str(window_id)], 
                             check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except subprocess.SubprocessError:
                print("Warning: Could not activate window")
        
        # Send the synthetic click
        success = self.send_click_event(target_x, target_y)
        
        if success:
            self.click_count += 1
            
            # Print status
            if self.max_clicks:
                print(f"Click {self.click_count}/{self.max_clicks} at ({rel_x}, {rel_y})")
            else:
                print(f"Click {self.click_count} at ({rel_x}, {rel_y})")
        else:
            print(f"Failed to click at position ({rel_x}, {rel_y})")
            
        return success
    
    def start_clicking(self):
        """Start the autoclicker"""
        if not self.selected_window:
            print("No window selected. Please select a window first.")
            return
            
        if not self.click_positions:
            print("No click positions defined. Please add at least one position.")
            return
            
        print(f"Starting XTest autoclicker (interval: {self.click_interval}s, jitter: {self.jitter}px)")
        if self.activate_window:
            print("Window activation: Enabled")
        else:
            print("Window activation: Disabled (clicks may not register in inactive windows)")
            
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
                
                # Send synthetic click at this position
                self.click_at_window_position(self.selected_window, rel_x, rel_y)
                
                # Move to next position (cycling through the list)
                position_index = (position_index + 1) % len(self.click_positions)
                
                # Wait for next click
                time.sleep(self.click_interval)
                
        except KeyboardInterrupt:
            print("\nStopping autoclicker")
            self.is_running = False
        finally:
            # Clean up X display connection
            self.display.close()

def main():
    parser = argparse.ArgumentParser(description="Automate clicking in a specific window without moving your cursor")
    parser.add_argument("--interval", type=float, default=1.0,
                       help="Time between clicks in seconds (default: 1.0)")
    parser.add_argument("--jitter", type=int, default=0,
                       help="Random jitter in pixels (default: 0)")
    parser.add_argument("--clicks", type=int,
                       help="Maximum number of clicks (default: unlimited)")
    parser.add_argument("--window-name", type=str,
                       help="Select window by name instead of clicking on it")
    parser.add_argument("--no-activate", action="store_true",
                       help="Don't activate the window before clicking (may not work with all applications)")
    
    args = parser.parse_args()
    
    try:
        # Check if xdotool is installed
        subprocess.run(["xdotool", "--version"], 
                      capture_output=True, check=True)
    except (subprocess.SubprocessError, FileNotFoundError):
        print("Error: xdotool is required but not found. Please install it:")
        print("  sudo apt-get install xdotool")
        return 1
    
    clicker = XTestAutoclicker()
    clicker.click_interval = args.interval
    clicker.jitter = args.jitter
    clicker.max_clicks = args.clicks
    clicker.activate_window = not args.no_activate
    
    # Setup wizard
    print("XTest Window Autoclicker")
    print("-----------------------")
    print("This tool sends synthetic mouse clicks to a window without moving your cursor")
    
    # Step 1: Select window (by name or by clicking)
    window_selected = False
    if args.window_name:
        window_selected = clicker.select_window_by_name(args.window_name)
    else:
        window_selected = clicker.select_window_by_click()
        
    if not window_selected:
        return 1
    
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
    
    return 0

if __name__ == "__main__":
    sys.exit(main())