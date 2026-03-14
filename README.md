# Transcript

A native macOS app that transcribes audio and video files to text using [OpenAI Whisper](https://github.com/openai/whisper). Everything runs locally — no cloud services, no API keys.

## Features

- **Drag-and-drop** — drop any audio/video file onto the window to transcribe
- **Multiple formats** — supports mp3, wav, m4a, flac, ogg, mp4, mov, mkv, avi, webm
- **Auto language detection** — works with any language (optimized for French and English)
- **Dual output** — generates `.txt` transcript and `.srt` subtitles
- **Speaker detection** — pause-based heuristic labels speakers A/B in text output
- **Real-time progress** — progress bar and live log during transcription
- **Configurable** — choose whisper model, output folder, and output formats from the sidebar

## Requirements

- macOS 14+
- [whisper](https://github.com/openai/whisper) CLI installed via Homebrew (`/opt/homebrew/bin/whisper`)
- [ffmpeg](https://ffmpeg.org/) installed via Homebrew (used by whisper internally)

### Install dependencies

```bash
brew install ffmpeg
pip3 install openai-whisper
```

## Build & Run

Open `Transcript.xcodeproj` in Xcode and hit Run, or build from the command line:

```bash
xcodebuild -scheme Transcript -configuration Release build
```

The whisper model (default: `medium`, ~1.5 GB) is downloaded automatically on first use.

## Architecture

```
Transcript/
├── TranscriptApp.swift          # App entry point
├── Models.swift                 # Data types, enums, errors
├── TranscriptionViewModel.swift # UI state management
├── ContentView.swift            # Main content area (drop zone, progress, results)
├── SidebarView.swift            # Settings panel
├── TranscriptionService.swift   # Whisper process runner, model management
├── SpeakerDetector.swift        # Pause-based speaker assignment
├── OutputGenerator.swift        # TXT and SRT file generation
└── ProcessUtilities.swift       # LineBuffer, ThrottledOutput helpers
```

## How it works

1. File is dropped onto the app window
2. Duration is probed with `ffprobe` for the progress bar
3. Whisper CLI runs with `--verbose True --output_format json`
4. Stdout/stderr are streamed to the log view (throttled to avoid excessive UI redraws)
5. Whisper's JSON output is parsed into segments
6. Speaker detection assigns labels based on pause gaps between segments
7. `.txt` and `.srt` files are written next to the input file (or to a custom folder)

## License

MIT
