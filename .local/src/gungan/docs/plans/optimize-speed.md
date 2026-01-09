# Optimising Gungan Transcription Speed

## Where time is spent today
- **Model inference (≈ 70 – 90 %)** – Whisper-large-v3 encoder KV-cache build and decoder beam search dominate.
- **Feature extraction (≈ 5 – 10 %)** – CPU Mel-spectrogram; FFT kernels are memory-bound.
- **Audio I/O & bookkeeping (≈ 5 – 15 %)** – resampling, media reads, JSON/SRT writes, currently done serially.

## Current road-blocks
1. **Single-GPU, single-batch flow** – GPU idles between clips.
2. **No quantisation** – only FP16; memory bandwidth wasted.
3. **FFT on CPU** – unused CUDA capacity.
4. **Python GIL & process layout** – caps parallelism for many short clips.
5. **External pre/post-processing** – spawning `ffmpeg` subprocesses adds latency.

## Action plan
- **Batch + stream decoding**
  Group similar-duration clips (`--batch_size`) and maintain KV-cache across segments.
- **Quantise the model**
  Int8 (SmoothQuant) or 4-bit (GPTQ) → 1.6-2 × speed-up with minimal WER change.
- **Move spectrograms to GPU**
  Use `torchaudio.transforms.MelSpectrogram(..., device="cuda")` or custom CUDA FFT.
- **Pipeline parallelism**
  1. CPU thread – demux/resample  
  2. GPU worker – Whisper  
  3. CPU thread – timestamps/output  
  Overlap stages to keep GPU busy.
- **Cache encoder output** when language-ID and transcription run back-to-back.
- **Consider smaller / specialised models**
  Distilled Whisper (~150 M params) or Conformer-Transducer models run 3-5 × faster.
- **Infrastructure tweaks**
  Large pages, CPU affinity, NVMe scratch space, PyTorch/CUDA compiled with `-O3 -march=native`.

---

_Update this document as benchmarks land and bottlenecks change._