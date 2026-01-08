# Gungan

Voice-to-text CLI using whisper-cpp. Named after Jar Jar Binks - "meesa transcribe your voice!"

## Why Gungan?

- **Fast**: Uses [whisper-cpp](https://github.com/ggerganov/whisper.cpp) (C++ implementation), not the slow Python OpenAI whisper
- **Simple**: Single command to record and transcribe
- **Clipboard-ready**: Output goes to both terminal and clipboard
- **Portable**: Standalone tool, works anywhere (not tied to a window manager)

## Quick Start

```bash
# Check everything is set up
./bin/gungan health

# Quick 5-second test
./bin/gungan test

# Or install system-wide
./install.sh
gungan test
```

## Commands

| Command | Description |
|---------|-------------|
| `gungan health` | Check all dependencies are installed |
| `gungan test [seconds]` | Quick recording test (default: 5s) |
| `gungan record` | Toggle: run once to start, again to stop |
| `gungan transcribe <file>` | Transcribe existing .wav file |
| `gungan help` | Show help |

## Requirements

### Binaries
- `whisper-cpp` - The fast C++ whisper implementation
- `pw-record` - Pipewire audio recording (comes with pipewire)
- `wl-copy` - Wayland clipboard (from `wl-clipboard` package)

### Model
Download a GGML model to `~/.local/share/whisper-models/`:
```bash
mkdir -p ~/.local/share/whisper-models
cd ~/.local/share/whisper-models

# Recommended: large-v3-turbo (1.6GB, best speed/quality balance)
wget https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

See [docs/installation.md](docs/installation.md) for full setup instructions.

## Installation

```bash
# Clone the repo
git clone https://github.com/yourusername/gungan.git
cd gungan

# Install (symlinks to ~/.local/bin/)
./install.sh

# Verify
gungan health
```

## Project Structure

```
gungan/
├── bin/
│   └── gungan          # Main CLI script
├── docs/
│   ├── installation.md # Full setup guide
│   └── troubleshooting.md
├── install.sh          # Installation script
└── README.md
```

## Why Not Python Whisper?

| Feature | whisper-cpp | Python whisper |
|---------|-------------|----------------|
| Speed | Fast (C++, GGML) | Slow (PyTorch) |
| Memory | Low (~2GB) | High (~6GB+) |
| GPU | AMD ROCm, CUDA, Metal | CUDA only |
| Model format | GGML quantized | Full FP16/32 |
| Dependencies | Minimal | Python + PyTorch |

## Integration

### Hyprland
Add to `~/.config/hypr/hyprland.conf`:
```conf
bind = $mainMod, V, exec, gungan record
```

### Other WMs
Bind `gungan record` to any hotkey in your window manager.

## License

MIT
