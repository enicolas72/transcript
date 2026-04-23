# xTranscript v1.0.0

A native macOS transcription tool — GUI app and command-line — that sends audio to **xAI's Speech-to-Text API** and writes `.txt` / `.srt` files with word-level timestamps and speaker labels.

## Features

- **GUI app + CLI** — drag-and-drop desktop app and `transcript` command-line tool
- **25 languages** via `grok-stt` (English, French, German, Spanish, Italian, Portuguese, Dutch, Russian, Chinese, Japanese, Korean, and more — plus an `auto` mode)
- **Multiple input formats** — mp3, wav, m4a, flac, aac, aiff, mp4, mov (anything AVFoundation can open)
- **Dual output** — `.txt` transcript and `.srt` subtitles
- **Speaker detection** — word-level speaker IDs returned by the API in a single call
- **Multi-file queue** — process multiple files sequentially, with per-file status tracking
- **Overwrite protection** — asks before overwriting existing output files (GUI)
- **Real-time progress** — progress bar and live log during transcription
- **Persistent settings** — API key, output folder, formats, language, and speaker detection are saved across launches (GUI)

## Requirements

- macOS 14+
- Xcode 16+ (for building)
- An xAI API key (get one at console.x.ai)
- Internet connection (every file is uploaded to xAI)

## Pricing

At the time of writing, xAI bills the STT API at **$0.10 per audio-hour** for batch transcription. See xAI's pricing page for the current rate.

## Build & Run

### GUI app

Open `Transcript.xcodeproj` in Xcode, select the **xTranscript** scheme, and hit Run. Paste your xAI API key into the Settings sidebar.

### Command-line tool

Select the **TranscriptCLI** scheme in Xcode and build, or:

```bash
xcodebuild -scheme TranscriptCLI -configuration Release build
```

Usage:

```bash
# Transcribe with speaker detection (default: .txt output, English).
# API key is read from $XAI_API_KEY (or --api-key, or the GUI-saved key).
export XAI_API_KEY=xai-...
transcript recording.mp4

# Multiple files, custom output dir, with SRT subtitles
transcript episode1.mp3 episode2.mp3 --output ~/transcripts --srt

# Disable speaker detection
transcript interview.wav --no-speakers

# Both formats
transcript podcast.m4a --txt --srt

# French (or any other language: de, es, it, pt, nl, ru, zh, ja, ko, auto)
transcript entretien.mp3 --language fr

# Pass the API key explicitly
transcript call.mp3 --api-key xai-abc123
```

Status messages go to stderr, output file paths go to stdout — so you can pipe: `transcript file.mp4 | xargs open`

## Architecture

```
Transcript/                         # GUI app (SwiftUI)
├── TranscriptApp.swift             # App entry point
├── Models.swift                    # Shared types (TranscriptionSettings, LabeledSegment, TranscriptLanguage, errors)
├── TranscriptionViewModel.swift    # UI state management, file queue, retry
├── ContentView.swift               # Three-column layout (sidebar, log, file queue)
├── SidebarView.swift               # Settings panel (output, language, formats, API key)
├── TranscriptionService.swift      # Orchestrator: open PCM stream → pipe through WebSocket → group → write (shared)
├── AudioExtractor.swift            # AVFoundation → chunked 16 kHz mono Int16 PCM reader (shared)
├── XAIClient.swift                 # Streaming client for wss://api.x.ai/v1/stt (shared)
└── OutputGenerator.swift           # TXT and SRT generation (shared)

TranscriptCLI/                      # Command-line tool
└── TranscriptCLI.swift             # ArgumentParser entry point (uses shared logic)
```

The 5 core logic files are shared between the GUI app and CLI targets. Only the UI files (`TranscriptApp`, `ViewModel`, `ContentView`, `SidebarView`) are app-specific.

## How it works

1. Files are dropped onto the right panel (multiple files supported, processed sequentially)
2. Existing output files are detected — user is prompted before overwriting
3. Audio is read as **16 kHz mono Int16 PCM** via AVFoundation (handles both audio and video files) and streamed in ~250 ms chunks
4. Each chunk is pushed over a **WebSocket to `wss://api.x.ai/v1/stt`** with `diarize=true` and the chosen language code; chunk-final partials stream back in real time
5. On `transcript.done` the full word list is grouped into speaker-coherent `LabeledSegment`s
6. `.txt` and `.srt` files are written next to the input file (or to a custom folder)

## Tests

Minimal unit tests cover the text/SRT formatting (`TranscriptTests/OutputGeneratorTests.swift`). Run them with `Cmd+U` in Xcode.

## Distribution

The app is configured for Mac App Store submission:

- **App Sandbox** is enabled (`Transcript.entitlements`) with
  `network.client` (for the xAI API) and `files.user-selected.read-write`
  (for dropped inputs and chosen output folders).
- **Privacy Manifest** at `Transcript/PrivacyInfo.xcprivacy` declares
  audio data collection with purpose = app functionality, and required-reason
  API use for `UserDefaults` and file metadata reads.
- **Bundle ID** is `com.ericnicolas.xtranscript` — **change this** to your
  own reverse-DNS (`com.yourdomain.xtranscript`) in `project.pbxproj`
  before submission.
- **Encryption export compliance**: `ITSAppUsesNonExemptEncryption = false`
  in `Info.plist` (system TLS only, no proprietary crypto).
- **Privacy policy** draft at `docs/privacy.md` — host it (e.g. GitHub
  Pages) and reference the public URL in App Store Connect.

To archive for submission: Xcode → Product → Archive → Distribute App →
App Store Connect. Requires an Apple Developer Program membership and
a matching Mac App Distribution certificate.

## License

MIT
