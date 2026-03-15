# Transcript

A native macOS app that transcribes audio and video files to text using [OpenAI Whisper](https://github.com/openai/whisper), with neural speaker diarization powered by [resemblyzer](https://github.com/resemble-ai/Resemblyzer). Everything runs locally — no cloud services, no API keys.

## Features

- **Drag-and-drop** — drop any audio/video file onto the window to transcribe
- **Multiple formats** — supports mp3, wav, m4a, flac, ogg, mp4, mov, mkv, avi, webm
- **Auto language detection** — works with any language (optimized for French and English)
- **Dual output** — generates `.txt` transcript and `.srt` subtitles
- **Neural speaker diarization** — identifies who spoke when, with automatic speaker count detection
- **Real-time progress** — progress bar and live log during transcription
- **Configurable** — choose whisper model, output folder, and output formats from the sidebar

## Requirements

- macOS 14+
- [whisper](https://github.com/openai/whisper) CLI installed via Homebrew (`/opt/homebrew/bin/whisper`)
- [ffmpeg](https://ffmpeg.org/) installed via Homebrew (used by whisper and for audio extraction)
- [resemblyzer](https://github.com/resemble-ai/Resemblyzer) Python package (for speaker detection): `pip3 install resemblyzer`

### Install dependencies

```bash
brew install ffmpeg
pip3 install openai-whisper resemblyzer
```

## Build & Run

Open `Transcript.xcodeproj` in Xcode and hit Run, or build from the command line:

```bash
xcodebuild -scheme Transcript -configuration Release build
```

The whisper model (default: `medium`, ~1.5 GB) is downloaded automatically on first use. The resemblyzer speaker encoder model is downloaded on first use as well.

## Architecture

```
Transcript/
├── TranscriptApp.swift          # App entry point
├── Models.swift                 # Data types, enums, errors
├── TranscriptionViewModel.swift # UI state management
├── ContentView.swift            # Main content area (drop zone, progress, results)
├── SidebarView.swift            # Settings panel
├── TranscriptionService.swift   # Whisper process runner, model management
├── diarize.py                   # Speaker diarization (resemblyzer embeddings + spectral clustering)
├── DiarizationService.swift     # FluidAudio wrapper (unused, kept as reference)
├── TranscriptMerger.swift       # Segment merger (unused, kept as reference)
├── OutputGenerator.swift        # TXT and SRT file generation
└── ProcessUtilities.swift       # LineBuffer, ThrottledOutput helpers
```

## How it works

1. Files are dropped onto the right panel (multiple files supported, processed sequentially)
2. Duration is probed with `ffprobe` for the progress bar
3. Whisper CLI runs with `--verbose True --output_format json --word_timestamps True`
4. Stdout/stderr are streamed to the log view (throttled to avoid excessive UI redraws)
5. Whisper's JSON output is parsed into segments with word-level timestamps
6. Audio is extracted to 16kHz mono WAV via ffmpeg
7. `diarize.py` computes speaker embeddings on sliding windows, clusters them, and assigns each word to a speaker
8. `.txt` and `.srt` files are written next to the input file (or to a custom folder)

## Speaker diarization

### Why neural diarization

The original speaker detection used 5 hand-crafted audio features (spectral centroid, spectral spread, RMS energy, zero-crossing rate, pitch) extracted per Whisper segment, then clustered with k-means into exactly 2 speakers. This approach had fundamental limitations:

- **Shallow features don't capture speaker identity** — two people with similar pitch and energy are indistinguishable
- **Fixed k=2** — couldn't handle monologues or 3+ speaker conversations
- **Whisper segments are pause-based, not speaker-based** — a single segment can contain two speakers
- **K-means with Euclidean distance on 5D features** — poor discriminative power for speaker separation

### Resemblyzer pipeline

The replacement uses [resemblyzer](https://github.com/resemble-ai/Resemblyzer) speaker embeddings with spectral clustering, invoked via a bundled Python script (`diarize.py`):

1. **GE2E speaker embeddings** — a neural network trained with generalized end-to-end loss computes 256-dimensional speaker identity vectors for overlapping 1.5-second audio windows (0.25s step)
2. **Spectral clustering** — automatically determines the number of speakers via silhouette score optimization, then assigns each window to a speaker cluster
3. **Word-level assignment** — Whisper's word-level timestamps map each word to the nearest embedding window's speaker
4. **Median smoothing** — a 7-word sliding window majority vote eliminates isolated single-word speaker flips

### Alternatives tested

| Approach | Result |
|----------|--------|
| Hand-crafted features + k-means (original) | Everything assigned to one speaker — features too shallow |
| FluidAudio (CoreML, pyannote+WeSpeaker+VBx) | Only 10-13 coarse segments for a 3-min conversation — too few turns detected, speaker assignment often wrong |
| resemblyzer + spectral clustering | Good speaker separation at word level, correct speaker identity, handles rapid back-and-forth |

FluidAudio was tested extensively with tuned config (finer step ratio, lower thresholds, reduced min segment duration) but its reconstruction pipeline fundamentally produces too-coarse segments for fast-paced conversations.

### How diarization works

1. Audio is extracted to 16kHz mono WAV via ffmpeg
2. Resemblyzer computes speaker embeddings for overlapping 1.5s windows across the full audio
3. Spectral clustering groups windows into speakers (auto-detects count via silhouette score)
4. Each Whisper word (with timestamp) is assigned to the speaker of the nearest embedding window
5. A 7-word median filter smooths isolated speaker label flips
6. Consecutive same-speaker words are grouped into paragraphs, labeled "Speaker A", "Speaker B", etc. by first appearance

If diarization fails for any reason, the app falls back gracefully to unlabeled transcript output.

## License

MIT
