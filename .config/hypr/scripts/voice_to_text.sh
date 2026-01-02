#!/bin/bash

# Configuration
MODEL="$HOME/.local/share/whisper-models/ggml-large-v3-turbo.bin"
AUDIO_FILE="/tmp/voice_sample.wav"
LOCK_FILE="/tmp/whisper_recording.lock"
WHISPER_BIN="/usr/local/bin/whisper-cpp"

if [ -f "$LOCK_FILE" ]; then
    # --- STOPPING ---
    rm "$LOCK_FILE"
    pkill -x pw-record
    pkill -RTMIN+8 waybar 
    
    notify-send "󰔊 Whisper" "Transcribing..." -t 800
    
    # Accelerated command for AMD GPU
    # --speed-up: uses lower precision for even faster inference
    # --language en: skips language detection for lower latency
    $WHISPER_BIN -m "$MODEL" -f "$AUDIO_FILE" -nt -l en --speed-up -otxt /tmp/whisper_out > /dev/null 2>&1
    
    if [ -f "/tmp/whisper_out.txt" ]; then
        RESULT=$(cat /tmp/whisper_out.txt | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Simple auto-punctuation fix if result is lowercase
        if [[ $RESULT =~ ^[a-z] ]]; then
            RESULT="$(tr '[:lower:]' '[:upper:]' <<< ${RESULT:0:1})${RESULT:1}."
        fi
        
        [ -n "$RESULT" ] && wtype "$RESULT "
        rm "/tmp/whisper_out.txt"
    fi
    rm "$AUDIO_FILE"
else
    # --- STARTING ---
    touch "$LOCK_FILE"
    pkill -RTMIN+8 waybar
    
    # Recording: 16khz mono. 
    # Use --volume 1.5 if your webcam mic is too quiet
    pw-record --format=s16 --rate=16000 --channels=1 "$AUDIO_FILE" &
fi
