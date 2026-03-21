# Transcript v0.1

A fully native macOS transcription tool — GUI app and command-line — with automatic speaker detection. Powered by [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet ASR + WeSpeaker diarization) via CoreML. Everything runs locally on-device — no cloud services, no API keys, no Python, no external dependencies.

## Features

- **GUI app + CLI** — drag-and-drop desktop app and `transcript` command-line tool
- **Multiple formats** — supports mp3, wav, m4a, flac, aac, aiff, mp4, mov
- **Dual output** — generates `.txt` transcript and `.srt` subtitles
- **Speaker detection** — identifies who spoke when, with automatic speaker count detection
- **Multi-file queue** — process multiple files sequentially, with per-file status tracking
- **Overwrite protection** — asks before overwriting existing output files (GUI)
- **Real-time progress** — progress bar and live log during transcription
- **Persistent settings** — output folder, formats, and speaker detection preferences are saved across launches (GUI)
- **Self-contained** — models download automatically on first use, no Homebrew or pip needed

## Requirements

- macOS 14+
- Xcode 16+ (for building)
- Internet connection on first run (to download ~700 MB of CoreML models)

## Build & Run

### GUI app

Open `Transcript.xcodeproj` in Xcode, select the **Transcript** scheme, and hit Run.

### Command-line tool

Select the **TranscriptCLI** scheme in Xcode and build, or:

```bash
xcodebuild -scheme TranscriptCLI -configuration Release build
```

Usage:

```bash
# Transcribe with speaker detection (default: .txt output)
transcript recording.mp4

# Multiple files, custom output dir, with SRT subtitles
transcript episode1.mp3 episode2.mp3 --output ~/transcripts --srt

# Disable speaker detection
transcript interview.wav --no-speakers

# Both formats
transcript podcast.m4a --txt --srt
```

Status messages go to stderr, output file paths go to stdout — so you can pipe: `transcript file.mp4 | xargs open`

On first use, models are downloaded automatically (~600 MB for ASR, ~100 MB for speaker embeddings). Subsequent runs are instant.

## Tests

The project includes unit tests and integration tests for the speaker detection pipeline.

### Running unit tests

Unit tests cover clustering algorithms and token processing. They run instantly with no external dependencies:

1. Open `Transcript.xcodeproj` in Xcode
2. Press `Cmd+U` to run all tests, or open the **Test Navigator** (diamond icon in the left sidebar) to run individual tests

### Integration tests and fixture snapshots

Integration tests in `SpeakerIntegrationTests.swift` run the real pipeline on audio fixtures in `TranscriptTests/Fixtures/`. Each fixture (e.g. `Joe Rogan 2331 - Jesse Michels.m4a`) generates matching snapshots with the same base name:

- **`.json`** — pre-computed embeddings for offline clustering non-regression
- **`.txt`** — reference transcript output for full-pipeline non-regression

To generate (or regenerate) snapshots:

1. **Run the app once** so that the WeSpeaker + ASR models are downloaded to Application Support
2. Open `TranscriptTests/SpeakerIntegrationTests.swift` in Xcode
3. In the editor gutter (left margin), find the **diamond icon** next to the test you want to run — click it to run just that test:
   - `testSpeakerEmbeddingsAreDifferentForDifferentSpeakers` generates the `.json` snapshot
   - `testFullPipelineTranscriptOutput` generates the `.txt` reference
4. **Commit the generated files** — from that point on, `testClusteringFromSnapshot` and `testFullPipelineTranscriptOutput` run as non-regression tests

To add a new fixture: drop an audio file in `TranscriptTests/Fixtures/`, update `fixtureName` in the test class, and run the integration tests to generate the snapshots.

## Architecture

```
Transcript/                         # GUI app (SwiftUI)
├── TranscriptApp.swift             # App entry point
├── Models.swift                    # Shared data types (TimedWord, LabeledSegment, errors)
├── TranscriptionViewModel.swift    # UI state management, file queue, retry
├── ContentView.swift               # Three-column layout (sidebar, log, file queue)
├── SidebarView.swift               # Settings panel
├── TranscriptionService.swift      # ASR + audio extraction (shared with CLI)
├── TranscriptMerger.swift          # Speaker detection orchestrator (shared)
├── SpeakerClustering.swift         # Pure math: k-means, silhouette scoring (shared)
├── SpeakerEmbedding.swift          # CoreML WeSpeaker embedding computation (shared)
└── OutputGenerator.swift           # TXT and SRT file generation (shared)

TranscriptCLI/                      # Command-line tool
└── TranscriptCLI.swift             # ArgumentParser entry point (uses shared logic)
```

The 6 core logic files are shared between the GUI app and CLI targets. Only the UI files (`TranscriptApp`, `ViewModel`, `ContentView`, `SidebarView`) are app-specific.

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
