# Transcript v0.1

A fully native macOS app that transcribes audio and video files to text with speaker detection. Powered by [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet ASR + WeSpeaker diarization) via CoreML. Everything runs locally on-device — no cloud services, no API keys, no Python, no external dependencies.

## Features

- **Drag-and-drop** — drop any audio/video file onto the window to transcribe
- **Multiple formats** — supports mp3, wav, m4a, flac, aac, aiff, mp4, mov
- **Dual output** — generates `.txt` transcript and `.srt` subtitles
- **Speaker detection** — identifies who spoke when, with automatic speaker count detection
- **Multi-file queue** — process multiple files sequentially, with per-file status tracking
- **Overwrite protection** — asks before overwriting existing output files
- **Real-time progress** — progress bar and live log during transcription
- **Persistent settings** — output folder, formats, and speaker detection preferences are saved across launches
- **Self-contained** — models download automatically on first use, no Homebrew or pip needed

## Requirements

- macOS 14+
- Xcode 16+ (for building)
- Internet connection on first run (to download ~700 MB of CoreML models)

## Build & Run

Open `Transcript.xcodeproj` in Xcode and hit Run, or:

```bash
xcodebuild -scheme Transcript -configuration Release build
```

On first use, the app downloads and compiles CoreML models (~600 MB for ASR, ~100 MB for speaker embeddings). Subsequent launches are instant.

## Architecture

```
Transcript/
├── TranscriptApp.swift          # App entry point
├── Models.swift                 # Data types, enums, errors
├── TranscriptionViewModel.swift # UI state management, file queue, overwrite check
├── ContentView.swift            # Three-column layout (sidebar, log, file queue)
├── SidebarView.swift            # Settings panel
├── TranscriptionService.swift   # ASR + audio extraction via FluidAudio/AVFoundation
├── TranscriptMerger.swift       # Per-sub-segment speaker embedding + clustering
└── OutputGenerator.swift        # TXT and SRT file generation
```

## How it works

1. Files are dropped onto the right panel (multiple files supported, processed sequentially)
2. Existing output files are detected — user is prompted before overwriting
3. Audio is extracted to 16kHz mono via AVFoundation (handles both audio and video files)
4. FluidAudio Parakeet ASR transcribes with word-level timestamps via CoreML (Neural Engine accelerated)
5. WeSpeaker neural embeddings are computed per sentence sub-segment for speaker identification
6. `.txt` and `.srt` files are written next to the input file (or to a custom folder)

## Speaker detection

### Pipeline

1. **Sentence splitting** — ASR tokens are split at sentence punctuation (`.` `?` `!`) into sub-segments (~3-10 words each)
2. **Per-sub-segment neural embeddings** — the FBank model converts each sub-segment's audio to mel features, then the WeSpeaker ResNet34 model produces a 256-dimensional speaker identity vector
3. **Cosine-similarity k-means clustering** — sub-segment embeddings are clustered with automatic speaker count detection via silhouette score optimization
4. **Sentence continuation carrying** — when a sub-segment continues an incomplete sentence (previous sub lacked punctuation) and its own cluster confidence is low, it inherits the previous speaker
5. **Run-length smoothing** — speaker runs shorter than 5 words are absorbed into neighbors

### Technology stack

| Component | Technology | Runs on |
|-----------|-----------|---------|
| Speech recognition | Parakeet TDT 0.6B (NVIDIA) | CoreML / Neural Engine |
| Speaker embeddings | WeSpeaker ResNet34 (per sub-segment) | CoreML / Neural Engine |
| Mel features | FBank model | CoreML / CPU |
| Speaker clustering | Cosine k-means + silhouette score | CPU (Accelerate/vDSP) |
| Audio extraction | AVFoundation (AVAssetReader) | CPU |

All ML inference runs on-device via CoreML with Apple Neural Engine acceleration. No Python, no external processes.

### Limitations

- ASR is English-only (Parakeet model). Multilingual support via Qwen3-ASR is possible but currently lacks word-level timestamps needed for speaker alignment.
- Speaker detection quality depends on how distinct the speakers' voices are. Fast-paced conversations with similar voices may have some boundary imprecision.

## License

MIT
