
This actually should be is record does this correctly. 

Stream should send out dictation as I say it at the same speed as record.And daemon should detect all words I say and prepare for commands that I make as well on top of that. 

That may be something on top of daemon that does the actual command processing.

Another nice to have would be if Markdown auto-wrapped. Words I said.

---

UPCOMING (ai generated)

  Summary of modes
  Command: record
  How it works: Press start → speak → press stop → transcribe
  Latency: ~2-3s after stop
  Best for: Dictation
  ────────────────────────────────────────
  Command: stream
  How it works: Rolling window every 3s
  Latency: ~3s
  Best for: Real-time preview
  ────────────────────────────────────────
  Command: daemon
  How it works: Detect speech → transcribe chunk → repeat
  Latency: ~2s after pause
  Best for: Continuous background
  Daemon mode uses:
  - Sox to detect speech start/end (silence detection)
  - whisper-cpp with GPU for fast transcription (same speed as record)
  - Runs continuously until you stop it

  Try it:
  # Start continuous listening
  gungan daemon

  # Or with auto-typing
  gungan --type daemon

  # Stop
  gungan daemon

