#!/bin/bash

# Function to disable screen saver and power saving
disable_screen_saver() {
    xset s off
    xset -dpms
    echo "Screen saver and power saving features disabled"
}

# Function to enable screen saver and power saving
enable_screen_saver() {
    xset s on
    xset +dpms
    echo "Screen saver and power saving features enabled"
}

# Get current hour (24-hour format)
hour=$(date +%H)

# Day time is considered from 7 AM (7) to 8 PM (20)
if [ $hour -ge 5 ] && [ $hour -lt 23 ]; then
    disable_screen_saver
else
    enable_screen_saver
fi
