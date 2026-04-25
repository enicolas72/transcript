# xTranscript v1.0.0

A native macOS transcription tool that sends audio to **xAI's Speech-to-Text API** and writes `.txt` / `.srt` files with word-level timestamps.

## Features

- **Drag-and-drop GUI** — multi-file queue with per-file status, retry, overwrite protection
- **11 languages** via `grok-stt` (English, French, German, Spanish, Italian, Portuguese, Dutch, Russian, Chinese, Japanese, Korean — xAI's streaming endpoint requires an explicit language)
- **Universal input format support** — every file is decoded by the embedded LGPL-only FFmpeg build (MP3, M4A, MP4, MOV, WAV, FLAC, AAC, AIFF, CAF, ALAC, MKV, WebM, OGG/Opus, AVI, WMV, WMA, …)
- **Dual output** — `.txt` transcript and `.srt` subtitles
- **Real-time progress** — progress bar and live log during transcription
- **Persistent settings** — API key, output folder, formats, language saved across launches
- **Free + Pro tiers** — see Pricing below

## Pricing

| Tier | What you get | Price |
|-|-|-|
| **Free** | Drag-and-drop transcription, all formats and languages, capped at **5 minutes per file** | — |
| **Pro** | Removes the 5-minute cap. Cancel anytime. | **$9.99 / year** |

Pro is an auto-renewable yearly subscription handled by Apple's App Store. xAI's own per-hour transcription cost is billed separately by xAI on your own API key — xTranscript Pro does **not** include xAI usage.

## Requirements

- macOS 14+
- Xcode 16+ (for building)
- An xAI API key (get one at console.x.ai)
- Internet connection (every file is uploaded to xAI)

## Build & Run

Open `Transcript.xcodeproj` in Xcode, select the **xTranscript** scheme, and hit Run. Paste your xAI API key into the Settings sidebar. The bundled `Transcript/Configuration/Products.storekit` file lets you test the Pro upgrade flow locally without a real Apple ID.

## Architecture

```
Transcript/                         # GUI app (SwiftUI)
├── TranscriptApp.swift             # App entry point
├── Models.swift                    # Shared types (TranscriptionSettings, LabeledSegment, TranscriptLanguage, errors)
├── TranscriptionViewModel.swift    # UI state management, file queue, retry
├── ContentView.swift               # Three-column layout (sidebar, log, file queue)
├── SidebarView.swift               # Settings panel (output, language, formats, API key)
├── TranscriptionService.swift      # Orchestrator: open PCM stream → pipe through WebSocket → group → write (shared)
├── AudioExtractor.swift            # Thin entry point: opens an FFmpegPCMReader
├── FFmpegPCMReader.swift           # LGPL FFmpeg decoder for every supported format
├── XAIClient.swift                 # Streaming client for wss://api.x.ai/v1/stt
├── OutputGenerator.swift           # TXT and SRT generation
├── SubscriptionManager.swift       # StoreKit 2: load product, purchase, restore
├── UpgradeView.swift               # Modal sheet pitching Pro + running the purchase flow
└── Configuration/Products.storekit # Local StoreKit testing config

Vendor/
└── FFmpeg.xcframework              # 7.6 MB universal static lib — built by scripts/build-ffmpeg.sh

TranscriptCLI/                      # Command-line tool
└── TranscriptCLI.swift             # ArgumentParser entry point (uses shared logic)
```

The 5 core logic files are shared between the GUI app and CLI targets. Only the UI files (`TranscriptApp`, `ViewModel`, `ContentView`, `SidebarView`) are app-specific.

## How it works

1. Files are dropped onto the right panel (multiple files supported, processed sequentially)
2. Existing output files are detected — user is prompted before overwriting
3. Audio is decoded to **16 kHz mono Int16 PCM** via the embedded LGPL FFmpeg build (`Vendor/FFmpeg.xcframework`) and streamed in ~250 ms chunks
4. Each chunk is pushed over a **WebSocket to `wss://api.x.ai/v1/stt`** with the chosen language code; chunk-final partials stream back in real time
5. On `transcript.done` the full word list is grouped into speaker-coherent `LabeledSegment`s
6. `.txt` and `.srt` files are written next to the input file (or to a custom folder)

## Tests

Minimal unit tests cover the text/SRT formatting (`TranscriptTests/OutputGeneratorTests.swift`). Run them with `Cmd+U` in Xcode.

## Rebuilding FFmpeg

The `Vendor/FFmpeg.xcframework` is checked into the repo (~7.6 MB). To
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

- **App Sandbox** is enabled (`Transcript.entitlements`) with
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

MIT
