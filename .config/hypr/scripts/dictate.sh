#!/bin/bash

# Configuration
MODEL_PATH="$HOME/.local/share/whisper-models/ggml-large-v3-turbo.bin"
TEMP_AUDIO="/tmp/dictation.wav"
WHISPER_BIN="whisper-cpp" # Or the full path to your whisper-cpp binary

if pgrep -x "sox" > /dev/null; then
    # --- STOP RECORDING ---
    pkill -x "sox"
    notify-send "Transcribing..." -t 1000
    
    # Run whisper-cpp (optimized for speed)
    # -nt: no timestamps, -otxt: output text file
    $WHISPER_BIN -m "$MODEL_PATH" -f "$TEMP_AUDIO" -nt -otxt /tmp/dictation_out > /dev/null 2>&1
    
    # Read the text and clean it up
    TEXT=$(cat /tmp/dictation_out.txt | tr -d '\n' | sed 's/^[[:space:]]*//')
    
    if [ -n "$TEXT" ]; then
        # Inject text into active window using wtype
        wtype "$TEXT"
    fi
    
    rm "$TEMP_AUDIO" "/tmp/dictation_out.txt"
else
    # --- START RECORDING ---
    notify-send "Recording..." "Speak now" -t 1000
    # Record at 16k (required by Whisper)
    sox -d -r 16000 -c 1 -b 16 "$TEMP_AUDIO" &
fi
