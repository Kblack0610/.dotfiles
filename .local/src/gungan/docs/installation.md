# Installation Guide

Complete setup guide for Gungan voice-to-text CLI.

## Prerequisites

### 1. Install whisper-cpp

whisper-cpp is the fast C++ implementation of OpenAI's Whisper model.

**Arch Linux:**
```bash
# Option A: From AUR
paru -S whisper-cpp

# Option B: Build from source (for AMD GPU support)
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
make -j$(nproc)
sudo cp main /usr/local/bin/whisper-cpp
```

**Other distros:**
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
make -j$(nproc)
sudo cp main /usr/local/bin/whisper-cpp
```

### 2. Install Audio Recording Tools

**Arch Linux:**
```bash
sudo pacman -S pipewire pipewire-pulse wireplumber
# pw-record comes with pipewire
```

**Debian/Ubuntu:**
```bash
sudo apt install pipewire pipewire-pulse wireplumber
```

### 3. Install Clipboard Tools (Wayland)

**Arch Linux:**
```bash
sudo pacman -S wl-clipboard
```

**Debian/Ubuntu:**
```bash
sudo apt install wl-clipboard
```

### 4. Download Whisper Model

Models are stored at `~/.local/share/whisper-models/`.

```bash
mkdir -p ~/.local/share/whisper-models
cd ~/.local/share/whisper-models
```

**Recommended: large-v3-turbo** (best speed/quality balance)
```bash
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
# Size: ~1.6GB
```

**Other options:**

| Model | Size | Quality | Speed |
|-------|------|---------|-------|
| tiny | 75MB | Low | Fastest |
| base | 142MB | Fair | Fast |
| small | 466MB | Good | Medium |
| medium | 1.5GB | Great | Slower |
| large-v3 | 3.1GB | Best | Slow |
| large-v3-turbo | 1.6GB | Great | Fast |

## Install Gungan

### Option A: Install Script
```bash
cd /path/to/gungan
./install.sh
```

### Option B: Manual Symlink
```bash
ln -sf ~/.local/src/gungan/bin/gungan ~/.local/bin/gungan
```

### Option C: Add to PATH
```bash
# Add to ~/.bashrc or ~/.zshrc
export PATH="$HOME/.local/src/gungan/bin:$PATH"
```

## Verify Installation

```bash
gungan health
```

Expected output:
```
Gungan Health Check
━━━━━━━━━━━━━━━━━━━━

Binaries:
[OK] whisper-cpp: /usr/local/bin/whisper-cpp
[OK] pw-record: /usr/bin/pw-record
[OK] wl-copy: /usr/bin/wl-copy

Model:
[OK] ggml-large-v3-turbo: ~/.local/share/whisper-models/ggml-large-v3-turbo.bin (1.6G)

[OK] All dependencies satisfied!
```

## AMD GPU Acceleration

For faster transcription on AMD GPUs:

1. Build whisper-cpp with ROCm support:
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
make -j$(nproc) GGML_HIPBLAS=1
sudo cp main /usr/local/bin/whisper-cpp
```

2. The `--speed-up` flag in gungan enables optimizations that benefit from GPU.

## Changing the Model

Edit the `MODEL` variable in `bin/gungan`:
```bash
MODEL="${MODEL_DIR}/ggml-base.bin"  # Use base model instead
```

Or create multiple model configs and switch between them.

## Next Steps

- Run `gungan test` to verify everything works
- See [troubleshooting.md](troubleshooting.md) if you encounter issues
- Add keybinding to your window manager (see README.md)
