# Troubleshooting

Common issues and solutions for Gungan.

## Audio Recording Issues

### No audio recorded / Empty transcription

**Check microphone is detected:**
```bash
# List audio sources
pw-record --list-targets

# Or with pactl
pactl list sources short
```

**Check microphone permissions:**
```bash
# Test recording manually
pw-record --format=s16 --rate=16000 --channels=1 /tmp/test.wav &
sleep 3
kill %1

# Play back to verify
pw-play /tmp/test.wav
# Or: aplay /tmp/test.wav
```

**Volume too low?**

Edit the pw-record command in `bin/gungan` to add `--volume`:
```bash
pw-record --format=s16 --rate=16000 --channels=1 --volume 1.5 "$AUDIO_FILE"
```

### Wrong microphone being used

Specify the microphone explicitly:
```bash
# List targets
pw-record --list-targets

# Add to the pw-record command:
pw-record --target <device-name> --format=s16 --rate=16000 --channels=1 "$AUDIO_FILE"
```

## Transcription Issues

### Slow transcription

1. **Use a smaller model:**
   ```bash
   # Download tiny model
   wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin
   ```
   Edit `bin/gungan` to use it.

2. **Enable GPU acceleration** (see installation.md)

3. **Reduce audio quality** (already optimized at 16kHz mono)

### Poor transcription accuracy

1. **Use a larger model:**
   - `ggml-large-v3-turbo.bin` is recommended
   - `ggml-large-v3.bin` for best accuracy (slower)

2. **Speak clearly** and reduce background noise

3. **Check audio quality:**
   ```bash
   gungan test 5
   # Listen to recording quality
   ```

### "Model not found" error

```bash
# Verify model location
ls -la ~/.local/share/whisper-models/

# Download if missing
mkdir -p ~/.local/share/whisper-models
cd ~/.local/share/whisper-models
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

## Clipboard Issues

### Text not copied to clipboard

**Check wl-copy is installed:**
```bash
which wl-copy
# Should show: /usr/bin/wl-copy
```

**Wayland session required:**
```bash
echo $XDG_SESSION_TYPE
# Should show: wayland
```

**X11 fallback:**
If on X11, install `xclip` and modify the script:
```bash
echo -n "$text" | xclip -selection clipboard
```

## Lock File Issues

### "Recording already in progress" but nothing recording

Clear stale lock file:
```bash
rm -f /tmp/gungan_recording.lock
pkill -f pw-record
```

### Multiple instances running

```bash
# Kill all gungan-related processes
pkill -f "pw-record.*gungan"
rm -f /tmp/gungan_recording.lock
```

## whisper-cpp Issues

### "whisper-cpp: command not found"

Check installation location:
```bash
# Common locations
ls -la /usr/local/bin/whisper-cpp
ls -la /usr/bin/whisper-cpp

# If installed elsewhere, update bin/gungan:
WHISPER_BIN="/path/to/your/whisper-cpp"
```

### Segmentation fault

Usually means model file is corrupted:
```bash
# Re-download model
cd ~/.local/share/whisper-models
rm ggml-large-v3-turbo.bin
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

## Debug Mode

Add debug output by running with bash debug:
```bash
bash -x ~/.local/src/gungan/bin/gungan test
```

## Getting Help

1. Run `gungan health` to check dependencies
2. Check this troubleshooting guide
3. Open an issue on GitHub with:
   - Output of `gungan health`
   - Error message
   - Your distro and version
