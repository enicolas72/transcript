# xTranscript v1.1.0

A free, open-source (MIT) native macOS transcription tool that sends audio to **xAI's Speech-to-Text API** and writes `.txt` / `.srt` files with word-level timestamps.

## Features

- **Drag-and-drop GUI** — multi-file queue with per-file status, retry, overwrite protection
- **11 languages** via `grok-stt` (English, French, German, Spanish, Italian, Portuguese, Dutch, Russian, Chinese, Japanese, Korean — xAI's streaming endpoint requires an explicit language)
- **Universal input format support** — every file is decoded by the embedded LGPL-only FFmpeg build (MP3, M4A, MP4, MOV, WAV, FLAC, AAC, AIFF, CAF, ALAC, MKV, WebM, OGG/Opus, AVI, WMV, WMA, …)
- **Dual output** — `.txt` transcript and `.srt` subtitles
- **Real-time progress** — progress bar and live log during transcription
- **Persistent settings** — API key, output folder, formats, language saved across launches
- **No limits, no accounts, no in-app purchases** — bring your own xAI API key; xAI bills the audio minutes directly to your account

## Requirements

- macOS 14+
- Xcode 16+ (for building)
- An xAI API key (get one at console.x.ai)
- Internet connection (every file is uploaded to xAI)

## Build & Run

Open `Transcript.xcodeproj` in Xcode, select the **xTranscript** scheme, and hit Run. Paste your xAI API key into the Settings sidebar.

## Architecture

```
Transcript/                         # SwiftUI app
├── TranscriptApp.swift             # App entry point
├── Models.swift                    # Shared types (TranscriptionSettings, LabeledSegment, TranscriptLanguage, errors)
├── TranscriptionViewModel.swift    # UI state management, file queue, retry, sandbox folder grants
├── ContentView.swift               # Three-column layout (sidebar, log, file queue)
├── SidebarView.swift               # Settings panel (output, language, formats, API key, acknowledgements)
├── TranscriptionService.swift      # Orchestrator: open PCM stream → pipe through WebSocket → group → write
├── AudioExtractor.swift            # Thin entry point: opens an FFmpegPCMReader, probes duration
├── FFmpegPCMReader.swift           # LGPL FFmpeg decoder for every supported format
├── XAIClient.swift                 # Streaming client for wss://api.x.ai/v1/stt
├── OutputGenerator.swift           # TXT and SRT generation
└── Resources/LICENSES.txt          # Bundled acknowledgements (shown in-app)

Vendor/
└── FFmpeg.xcframework              # ~7.7 MB universal static lib — built by scripts/build-ffmpeg.sh

TranscriptTests/                    # XCTest: output formatting + FFmpeg decoder fixtures
```

## How it works

1. Files are dropped onto the right panel (multiple files supported, processed sequentially)
2. Existing output files are detected — user is prompted before overwriting
3. Audio is decoded to **16 kHz mono Int16 PCM** via the embedded LGPL FFmpeg build (`Vendor/FFmpeg.xcframework`) and streamed in ~250 ms chunks
4. Each chunk is pushed over a **WebSocket to `wss://api.x.ai/v1/stt`** with the chosen language code; chunk-final partials stream back in real time
5. On `transcript.done` the chunk-final partials are mapped to `LabeledSegment`s (one per ~3 s server chunk)
6. `.txt` and `.srt` files are written next to the input file (or to a custom folder)

Speaker diarization is wired end to end but currently forced off: xAI's streaming endpoint runs out of memory with `diarize=true` on inputs longer than about a minute (reported upstream, 2026-04-22). The toggle in `SidebarView` is commented out until xAI ships a fix.

## Tests

18 unit tests cover the text/SRT formatting (`TranscriptTests/OutputGeneratorTests.swift`) and the FFmpeg decoder on small MKV/WebM/OGG/MP3 fixtures (`TranscriptTests/FFmpegPCMReaderTests.swift`). Run them with `Cmd+U` in Xcode, or:

```bash
xcodebuild -project Transcript.xcodeproj -scheme xTranscript -destination 'platform=macOS' test
```

## Rebuilding FFmpeg

The `Vendor/FFmpeg.xcframework` is checked into the repo (~7.7 MB). To
rebuild it from source — for an FFmpeg version bump or a CVE refresh —
run:

```bash
./scripts/build-ffmpeg.sh --clean
```

The script clones the pinned FFmpeg tag (see `scripts/build-ffmpeg.sh`
for the version), configures it with `--disable-everything` and an
explicit allow-list of audio demuxers/decoders/parsers (no GPL or
non-free codecs, no network/protocol code), builds for arm64 + x86_64,
and packages the result as a static XCFramework. Verifies post-build
that no `x264`/`x265`/`fdk`/`amr`/`gsm` symbols leaked in.

## Distribution

The app is configured for Mac App Store submission:

- **App Sandbox** is enabled (`Transcript/xTranscript.entitlements`) with
  `network.client` (for the xAI API) and `files.user-selected.read-write`
  (for dropped inputs and chosen output folders).
- **Privacy Manifest** at `Transcript/PrivacyInfo.xcprivacy` declares
  audio data collection with purpose = app functionality, and required-reason
  API use for `UserDefaults` and file metadata reads.
- **Bundle ID** is `net.eric-nicolas.xtranscript` (reverse-DNS of
  `eric-nicolas.net`).
- **Encryption export compliance**: `ITSAppUsesNonExemptEncryption = false`
  in `Info.plist` (system TLS only, no proprietary crypto).
- **Privacy policy** lives at `docs/privacy.md` and is served directly by
  GitHub — no separate web hosting needed. Use these URLs in App Store
  Connect:
  - Privacy policy URL: https://github.com/enicolas72/transcript/blob/main/docs/privacy.md
  - Support URL: https://github.com/enicolas72/transcript/issues

To archive for submission: Xcode → Product → Archive → Distribute App →
App Store Connect. Requires an Apple Developer Program membership and
a matching Mac App Distribution certificate.

## License

MIT — see [LICENSE](LICENSE). The embedded FFmpeg build is LGPL-2.1+;
its notice and source-availability pointer are in
`Transcript/Resources/LICENSES.txt` and shown in-app under
Acknowledgements.
