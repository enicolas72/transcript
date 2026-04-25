# Development Log

## 2026-04-25 (later) — FFmpeg as the only decoder; drop the AVFoundation backend

### What was done

- **Deleted the AVFoundation backend.** With the FFmpeg XCFramework already shipping (7.6 MB, paid for), running two decoders for two halves of the format set was complexity without payoff: the bottleneck is the network call to xAI, not decode speed. One backend = one bug surface, one log line, one set of tests.
- **`PCMReader` protocol gone**, `AVFoundationPCMReader` deleted. `AudioExtractor.openPCMReader(_:)` now just constructs an `FFmpegPCMReader`. `XAIClient.streamingTranscribe(reader:)` takes a concrete `FFmpegPCMReader`. `backendName` removed.
- **Made the FFmpeg build a strict superset of AVFoundation.** Added `caf` to the demuxer enable-list and `alac` to the decoder enable-list in `scripts/build-ffmpeg.sh` so we don't lose Apple Lossless / Core Audio Format support that AVFoundation handled natively. XCFramework rebuilt (~7.7 MB now, +0.1 MB).
- **AVFoundation is still used in one place: `AudioExtractor.probeDuration`.** It's a fast, header-only duration probe used purely for the log line. Cheap and accurate on every container we accept; if it fails, we just don't log the duration line.
- **MP3 fixture test added** (`testDecodesMP3` in `FFmpegPCMReaderTests`) to verify the FFmpeg path also handles formats AVFoundation used to handle natively. 17 → **18 tests**.

### Why now

We weighed the trade-off: dropping AVFoundation means losing hardware decoding (irrelevant — xAI network call dominates) and any Apple-specific edge-case handling. We weighed those against a strictly simpler codebase (one decoder, one log path, one set of failures). The tipping factor: fewer ways for a user to hit a "weird format" bug.

## 2026-04-25 — Embed FFmpeg as fallback decoder (MKV / WebM / OGG / AVI / WMV)

### What was done

- **Built an audio-only LGPL FFmpeg XCFramework** at `Vendor/FFmpeg.xcframework` (universal arm64 + x86_64, **7.6 MB**). The build is reproducible via `scripts/build-ffmpeg.sh`: clones FFmpeg `n7.1.1`, configures with `--disable-everything` then an explicit allow-list of demuxers (matroska/ogg/mov/mp3/wav/flac/aac/aiff/mp4/avi/asf), audio decoders (opus/vorbis/mp3/aac/flac/ac3/eac3/wmav1/wmav2/wmavoice/wmapro/pcm_*), and parsers. No GPL components, no non-free codecs, no network protocols (only `--enable-protocol=file`), no asm. Post-build the script greps for `x264`/`x265`/`fdk`/`gsm`/`amr`/`theora`/`opencore`/`wavpack_encoder` symbols — fails the build if any leak in.
- **`PCMReader` is now a protocol** with two backends (`AudioExtractor.swift`):
  - `AVFoundationPCMReader` — fast path for everything Apple opens natively (MP3/M4A/MP4/MOV/WAV/FLAC/AAC/AIFF/CAF).
  - `FFmpegPCMReader` (`FFmpegPCMReader.swift`) — Swift bridge over libavformat/libavcodec/libswresample. RAII-style lifecycle for `AVFormatContext`/`AVCodecContext`/`SwrContext`/`AVPacket`/`AVFrame`. Decodes any audio stream, resamples to 16 kHz mono S16-LE via `swr_convert`, yields the same chunked shape as the AVFoundation backend.
- **`AudioExtractor.openPCMReader(_:)` is now a dispatcher** — tries AVFoundation, falls back to FFmpeg on refusal. `TranscriptionService` now logs `Opened via AVFoundation` or `Opened via FFmpeg` so users (and us) can tell which backend handled a file.
- **Module map.** `Vendor/FFmpeg.xcframework/.../Headers/module.modulemap` lists the ~25 headers we actually use. Originally tried `umbrella "."` and got bitten by FFmpeg's platform-specific hardware-accel headers (d3d11va.h, hwcontext_cuda.h, …) trying to include Windows/Linux-only system headers; the explicit list dodges them.
- **CFFmpeg module imports cleanly** from Swift, full Swift bridge sketch is ~280 lines, all type-checked end-to-end. The XCFramework links statically into both the app dylib and the CLI binary (no embedded framework copy needed for static libs).
- **Universal universe of UI affordances:**
  - `supportedExtensions` extended with `mkv, webm, ogg, opus, oga, avi, wmv, wma, asf, m4v, ts`.
  - Drop-zone copy in `ContentView` updated to advertise the new formats.
  - **Acknowledgements sheet** added to `SidebarView`. A "Acknowledgements…" link at the bottom of the sidebar opens a modal with the full text of the bundled `Resources/LICENSES.txt` (FFmpeg LGPL notice, GitHub release link for source-code availability, plus xTranscript's own MIT and ArgumentParser's Apache-2 notices). Required for LGPL §6 compliance.
  - `LICENSES.txt` is wired into the app target's Resources phase so it ships inside the bundle.
- **Tests.** Three small fixtures (each <8 KB) are committed in `TranscriptTests/Fixtures/`: `sine.mkv` (AAC), `sine.webm` (Opus), `sine.ogg` (Opus) — generated from a 2-second 440 Hz sine via the system ffmpeg. `FFmpegPCMReaderTests` reads each, verifies chunked S16-LE output, and asserts the total byte count is within ±10 % of the expected 64 000 bytes (2 s × 16 kHz × 2 B/sample). All three pass; total test count 14 → **17**.
- **Provenance.** `Vendor/FFmpeg-source-tag.txt` records the exact FFmpeg SHA, configure flags, build host, SDK, and the LGPL §6 source-code download URL. Re-emitted on every script run.

### App Store risk-mitigation work delivered

1. ✅ Attribution UI: Acknowledgements sheet in the sidebar.
2. ✅ Source-code availability link in the manifest, pointing at GitHub Releases (we'll attach the FFmpeg source tarball + build script to each release that bumps the FFmpeg version).
3. ✅ No-GPL-leak check baked into `scripts/build-ffmpeg.sh`.
4. ✅ Bundled `LICENSES.txt` in `Resources/`.
5. ✅ No new entitlements needed — `--disable-network` in the FFmpeg build means it never tries to open a socket; the existing `network.client` covers xAI alone.
6. ✅ Hardened runtime works as-is — static linking, no dlopen, no JIT.

### Known limitation

- `--disable-asm` was used to avoid Yasm/NASM dependency surface. We give up some decode speed (typically 5-15 % slower than asm-optimised builds) — fine for a desktop app where transcription is bottlenecked on the network call to xAI anyway.

## 2026-04-23 (latest) — Finalize bundle ID + host-free App Store URLs

### What was done

- **Bundle ID finalized** as `net.eric-nicolas.xtranscript` (reverse-DNS of the domain we own, `eric-nicolas.net`). Updated `PRODUCT_BUNDLE_IDENTIFIER` in both build configs. `Info.plist` already referenced `$(PRODUCT_BUNDLE_IDENTIFIER)` so no change there. Fixed the stale `defaults delete` command in `docs/privacy.md`.
- **Hosting-free App Store Connect setup.** We don't want to run a marketing site, so instead:
  - Privacy policy URL → `https://github.com/enicolas72/transcript/blob/main/docs/privacy.md` (GitHub renders markdown natively; Apple accepts GitHub URLs).
  - Support URL → `https://github.com/enicolas72/transcript/issues`.
  No DNS records, no GitHub Pages, no `CNAME` file required.

### Verified

- pbxproj still lints clean (`plutil -lint`).
- `xcodebuild -showBuildSettings` confirms `PRODUCT_BUNDLE_IDENTIFIER = net.eric-nicolas.xtranscript`.
- Debug build succeeds; 15 unit tests still pass (no code paths touched, only identifiers and docs).

## 2026-04-23 (later) — Mac App Store prep: sandbox, privacy manifest, bookmarks

### What was done

- **App Sandbox enabled** in `Transcript.entitlements` with:
  - `com.apple.security.app-sandbox = true`
  - `com.apple.security.network.client = true` (outbound to api.x.ai)
  - `com.apple.security.files.user-selected.read-write = true` (dropped inputs + chosen output folders)
- **Security-scoped bookmarks** for the custom-output-folder setting. Under sandbox, a raw path string persisted to `UserDefaults` is useless across launches; `TranscriptionSettings` now stores `outputFolderBookmark` (Data) via `URL.bookmarkData(options: .withSecurityScope)` and resolves it on `init`, calling `startAccessingSecurityScopedResource()` so the scope is held for the app's lifetime. The old `outputFolder` key is no longer written.
- **Bundle identifier** bumped from the local-dev placeholder `com.local.transcript` to `com.ericnicolas.xtranscript`. `Info.plist` now references `$(PRODUCT_BUNDLE_IDENTIFIER)` so the canonical definition lives in one place (pbxproj). **The chosen reverse-DNS is still a placeholder — search-replace before uploading to App Store Connect if you want a different domain.**
- **Privacy Manifest** at `Transcript/PrivacyInfo.xcprivacy`, added to the Xcode project and the app target's Resources build phase so it ships in the bundle. Declares:
  - `NSPrivacyTracking = false`, no tracking domains.
  - Required-reason APIs: `UserDefaults` (reason `CA92.1`) + `FileTimestamp` (reason `3B52.1` for file size on user-provided files).
  - Collected data: `AudioData`, not linked to user, not tracking, purpose = `AppFunctionality` (xAI transcription).
- **Privacy policy** draft at `docs/privacy.md`. Host it at a public URL and paste the URL into App Store Connect. Reasonable GitHub Pages candidate.

### Build verification

- `codesign -d --entitlements -` on the built Debug `xTranscript.app` shows sandbox + network.client + user-selected.read-write are embedded.
- `PrivacyInfo.xcprivacy` lands in `Resources/` inside the bundle.
- 15 unit tests still pass.

### Still to do before submitting

- Apple Developer Program membership ($99/year).
- Provision `com.ericnicolas.xtranscript` (or your chosen ID) as an App ID at developer.apple.com.
- Create Mac App Distribution + Mac Installer Distribution certificates (Xcode does this automatically when you archive).
- Create App Store Connect listing: name, description, keywords, screenshots (1280×800+), support URL, privacy-policy URL, pricing.
- Reserve a unique App Store name (beware collisions with existing "Transcript"-prefixed apps).
- Test the sandboxed Release build end-to-end: drop a file, save the API key, pick a custom output folder, relaunch, confirm the bookmark resolves and the folder is still writable.
- App Review prep: "Demo Account / API Access" in App Store Connect — provide a throwaway xAI key reviewers can use, plus a one-line explanation of the BYO-key model.

### Known risks

- The "same as input" output mode may fail under sandbox if macOS doesn't grant write access to the dropped file's parent directory. If so, we'll need to either require a user-selected output folder for sandboxed builds or add a fallback to `~/Downloads`.
- App Store review sometimes flags BYO-API-key apps as "not fully functional" under Guideline 2.1 / 4.2. If this becomes a blocker, distributing a notarized DMG outside the App Store is a viable alternative.

## 2026-04-23 — v1.0.0, rename to xTranscript, more unit tests

### What was done

- **Renamed the app to xTranscript.** `PRODUCT_NAME` → `xTranscript`; built bundle is now `xTranscript.app` with `CFBundleName` / `CFBundleDisplayName` / `CFBundleExecutable` all matching. `PRODUCT_MODULE_NAME` is pinned to `Transcript` so `@testable import Transcript` in the test target keeps working without a module rename.
- **Scheme renamed** `Transcript.xcscheme` → `xTranscript.xcscheme` via `git mv`. `BuildableName` references updated. Test host in `TranscriptTests` retargeted at `xTranscript.app/Contents/MacOS/xTranscript`.
- **Version bumped to 1.0.0.** `MARKETING_VERSION` in both Debug/Release configs + `CFBundleVersion` / `CFBundleShortVersionString` in `Info.plist`.
- **App Store pre-reqs in Info.plist:** added `ITSAppUsesNonExemptEncryption = false` (we use system TLS only — short-circuits the export-compliance questionnaire on submission).
- **Test coverage expanded** (4 → 15). `OutputGeneratorTests.swift` now covers:
  - `generateTXT` — joins segments with `\n`, empty case.
  - `generateSRT` — single-cue format, sequential numbering across cues, HH:MM:SS,mmm timestamp formatting, speaker prefix toggle, empty-text skip.
  - `TranscriptLanguage.xAICode` — `en`, `auto` (nil), `fr`.
- **What's still untested:** audio extraction (needs fixture files), xAI WebSocket transport (needs URLSession mock). Neither is a great ROI right now.

### Not touched (deliberately)

- `Transcript.xcodeproj` / source folder / `TranscriptCLI` binary name. These are internal structure, not user-visible. The CLI stays `transcript` (conventional, lowercase).
- Bundle identifier (`com.local.transcript`). Will need a real reverse-DNS ID before App Store submission.
- App Sandbox is still off. Enabling it is mandatory for Mac App Store and requires `com.apple.security.network.client` + `com.apple.security.files.user-selected.read-write`.

## 2026-04-22 (latest) — Temporarily disable speaker detection (xAI diarize OOMs)

### What was done

- **Hid the "Speaker detection" toggle** in `SidebarView`. The `speakerDetection` setting still lives in `TranscriptionSettings` / `UserDefaults` so the toggle can be re-enabled in one commented-out block once xAI ships a fix.
- **Pinned `speakerDetection: false`** at both service call sites (`TranscriptionViewModel` for the GUI, `TranscriptCLI` for the command line). Belt-and-suspenders — even if an old UserDefaults value persisted `true`, the call site overrides it.
- **CLI `--speakers` flag now defaults to `false`** and prints a one-line note if the user explicitly passes `--speakers`. Help text updated to call out the status.

### Why

Upstream bug: `wss://api.x.ai/v1/stt?diarize=true` and `POST /v1/stt` with `diarize=true` both return `CUDA error: out of memory` (or `CUBLAS_STATUS_INTERNAL_ERROR`) on anything longer than ~1 minute. Even an 11-minute clip reliably triggers it. With `diarize=false` the streaming path is clean — great transcription quality confirmed by the user. Support request has been filed with xAI.

### How to restore when xAI fixes it

1. Un-comment the Toggle block in `SidebarView.swift`
2. Restore `speakerDetection: capturedSettings.speakerDetection` in `TranscriptionViewModel`
3. Restore `speakerDetection: speakers` + the default `= true` on `--speakers` in `TranscriptCLI`
4. Remove the warning note in `TranscriptCLI`

## 2026-04-22 (later) — Switch from batch POST to streaming WebSocket

### What was done

- **Replaced `POST /v1/stt` with `wss://api.x.ai/v1/stt`.** The batch POST timed out at exactly our `timeoutIntervalForRequest` ceiling (300 s) on a 107-minute file — the API can't assemble a transcript for that size synchronously inside a single HTTP request. The streaming endpoint processes chunks as they arrive, so the round-trip matches the duration of the upload, not the duration of the audio.
- **New `AudioExtractor.PCMReader`.** `AVAssetReader` + `AVAssetReaderTrackOutput` configured for 16 kHz mono Int16 LE. `next()` returns the next ~16 kB (~250 ms) chunk; nil when exhausted. We never hold more than one chunk in memory, so RAM usage is flat regardless of audio length.
- **`XAIClient.streamingTranscribe`.** Opens a `URLSessionWebSocketTask` with `Authorization: Bearer …` and query params (`sample_rate=16000&encoding=pcm&diarize=true&language=…`). Uses `withThrowingTaskGroup` to run a sender (PCM chunks → binary frames → `{"type":"audio.done"}` sentinel) concurrently with a receiver loop that decodes `transcript.partial` / `transcript.done` events.
- **Chunk-final partials stream into the log.** Every `transcript.partial` with `is_final=true` (≈ every 3 s of speech) is logged with a `…` prefix, so the user sees words appearing live. The authoritative words list still comes from `transcript.done`.
- **Real upload progress.** Progress bar maps bytes-sent / total-PCM-bytes into 10–85 %; the remaining 15 % covers the tail between the last audio chunk and `transcript.done` + disk writes.
- **Dropped** the intermediate M4A transcoding step — streaming PCM straight from `AVAssetReader` removes the temp file, removes the AAC encoder pass, and removes the in-memory multipart body we were building for the batch POST.

### Bug fixed along the way

- `CMBlockBufferGetDataPointer` returns only the first contiguous range; switched to `CMBlockBufferGetDataLength` + `CMBlockBufferCopyDataBytes` so multi-block PCM buffers from `AVAssetReader` are fully captured.

## 2026-04-22 — Replace on-device pipelines with the xAI Speech-to-Text API

### What was done

- **Removed the two on-device ASR pipelines** (Parakeet for English + Qwen3-ASR for other languages) along with the WeSpeaker diarization stack. A single call to xAI's new `POST https://api.x.ai/v1/stt` endpoint now returns word-level timestamps *and* integer per-word speaker IDs in one shot.
- **New `XAIClient`** — tiny multipart uploader. Streams the WAV body to disk, then `URLSession.upload(fromFile:)`s it with `language`, `diarize=true`, and `file` as the last multipart field (xAI requires this ordering). Decodes `{text, language, duration, words[{text, start, end, speaker?}]}`.
- **New `AudioExtractor`** — replaces `FluidAudio.AudioWAV`. Uses `AVAssetReader` + `AVAssetWriter` to transcode any supported container into mono **AAC/M4A** at 16 kHz / 32 kbps. Speech lands at ~14 MB per hour (compare: 115 MB/h for the interim 16-bit PCM WAV we tried first), which uploads in seconds on a normal connection. _Note: the first cut of this change went out as uncompressed WAV and tripped URLSession's 60 s request timeout on a 107-min file; switched to AAC and raised the session timeouts (5 min per request, 1 h per resource) as the fix._
- **`TranscriptionService` is now ~130 lines** (was 436). Single path: extract → upload → group words into `LabeledSegment`s by speaker boundary → write TXT/SRT. No more Parakeet/Qwen3 branching, no `@available(macOS 15, *)` dance, no CoreML model downloads, no per-turn ASR loop.
- **API key stored in UserDefaults** (`xAIApiKey`), with a SecureField in the Settings sidebar. CLI reads the key from `--api-key`, then `$XAI_API_KEY`, then UserDefaults.
- **Deleted** `TranscriptMerger.swift`, `SpeakerClustering.swift`, `SpeakerEmbedding.swift`, `SpeakerTool/` (standalone SPM package that duplicated the diarization logic), the `TranscriptTests/Fixtures/` audio + snapshots, `SpeakerIntegrationTests.swift`, and `TranscriptMergerTests.swift`. The `FluidAudio` SPM dependency is gone from `project.pbxproj` on both targets.
- **`OutputGenerator` consolidated** on `LabeledSegment`. Two public entry points: `generateTXT`/`generateTXTWithSpeakers` and a single `generateSRT(_:withSpeakers:)`. The old token-based formatters (which leaked `FluidAudio.TokenTiming` into outputs) are gone.
- **README overhauled** for the new architecture and API-key requirement. Pricing referenced ($0.10/audio-hour at the time of writing).

### Design decisions

- **Always transcode to WAV before upload.** xAI auto-detects most containers (MP3, M4A, MP4, FLAC, OGG, MKV…) but not AIFF or MOV. A uniform 16 kHz mono 16-bit PCM WAV keeps every input on the same code path and is already what the API prefers. For a 1-hour file this is ~115 MB.
- **UserDefaults over Keychain** for the API key. Per user preference — this is a local dev tool, not a distributed app. Trivial to migrate to Keychain later if needed.
- **Diarization is "per-word speaker IDs", not "speaker turns".** The API returns an integer `speaker` field on each word. The service groups consecutive same-speaker words into `LabeledSegment`s at the boundary, then relabels `{0,1,…}` → `"Speaker A", "Speaker B", …` in first-appearance order so the downstream TXT/SRT formatters stay unchanged.
- **Streaming multipart + streaming WAV write.** Both the PCM encode and the multipart body are written to disk in chunks to keep peak RAM roughly the size of the Float32 sample buffer, not double that.

### Ripple effects

- Binary size drops dramatically (no CoreML weights bundled, no FluidAudio). First-run UX is "paste an API key" instead of "download ~700 MB–2.5 GB of models".
- macOS 15 requirement for non-English is gone. Every language now works on macOS 14+.
- Accuracy is now xAI's problem; on their phone-call benchmark Grok STT reports 5.0% WER, against WeSpeaker+Parakeet/Qwen3 we were subject to two independent error budgets stacked end-to-end.

## 2026-04-07 — Multilingual transcription via Qwen3-ASR (diarize-first pipeline)

### What was done

- **Added French + 9 other languages** (`de, es, it, pt, nl, ru, zh, ja, ko`, plus `auto`) on top of the existing English path. New `TranscriptLanguage` enum in `Models.swift`, persisted in `TranscriptionSettings`.
- **New pipeline path** in `TranscriptionService.swift`: when language is non-English, route to `runQwen3Pipeline` (`@available(macOS 15, *)`). English keeps the unchanged Parakeet path.
- **`SpeakerDiarizer`** (in `SpeakerEmbedding.swift`): audio-driven sliding-window diarizer. 2-second non-overlapping windows → WeSpeaker embeddings → `SpeakerClustering.clusterEmbeddings` (silhouette-scored automatic k) → run-length smoothing → consecutive-window merge into `Turn(start, end, speaker)`. Independent of any ASR output.
- **Per-turn ASR** in the Qwen3 path: each diarized turn's audio slice is fed to `Qwen3AsrManager.transcribe(audioSamples:language:)`. Output `LabeledSegment`s map directly to TXT/SRT.
- **`OutputGenerator`** gained `generateTXTFromSegments` and `generateSRTFromSegments` for the segment-based (no word-timestamps) Qwen3 path. SRT cues are turn-level.
- **Sidebar language picker** (`SidebarView`) and **`--language`/`-l` CLI flag** (`TranscriptCLI`) thread the choice through to the service.
- **README + THOUGHTS updated** to document the inverted Qwen3 pipeline, the macOS 15 requirement for non-English, the `~1.75 GB` model footprint, and the trade-offs (per-turn cost, turn-level SRT granularity).

### Bugs fixed along the way

- **`PRODUCT_MODULE_NAME` collision** between the `Transcript` app target and the lowercase `transcript` CLI target. On case-insensitive APFS, `Transcript.swiftmodule` and `transcript.swiftmodule` collided in `Build/Products/Debug/`, the CLI's lowercase version overwrote the app's, and `@testable import Transcript` from the test target found nothing ("Unable to resolve module dependency: 'Transcript'"). Fixed by setting `PRODUCT_MODULE_NAME = TranscriptCLI` on the CLI target's Debug+Release configs while leaving the binary product name as `transcript`.
- **`AsrManager.initialize(models:)` → `loadModels(_:)`** rename in the bumped FluidAudio version.
- **`SpeakerClustering.silhouetteScore`** produced NaN for singleton clusters and made `clusterEmbeddings` over-cluster (k=5 winning over k=3 in tests). Now follows the sklearn convention: singleton clusters score 0, and `(b - a) / max(a, b)` is guarded against `0/0`.
- **`TranscriptMerger.smoothRuns` (and parallel `SpeakerDiarizer.smoothLabels`)** cascaded wrongly when multiple adjacent runs were all below the threshold: a boundary run flipped into the next speaker, then the new boundary flipped, etc., propagating across the whole array. Fixed by only absorbing interior runs (`i > 0 && j < count`). Boundary noise is left alone; this matches the documented "absorb short interior runs into neighbours" intent.

### Design decisions

- **Diarize-first, transcribe-per-turn** (vs. transcribe-once-then-align). Qwen3-ASR returns no word-level timing, so any "single ASR call + alignment" approach would have to guess turn boundaries from character counts. Per-turn ASR is slower but structurally accurate — each turn's text comes from a single dedicated ASR call.
- **`SpeakerDiarizer` lives inside `SpeakerEmbedding.swift`** (rather than its own file) to avoid editing the dense `project.pbxproj` for both targets. Same dependency surface, no behavioural cost.
- **Type-erased `_qwen3Manager: Any?` cache** in `TranscriptionService` to avoid `@available` headaches on stored properties. Cast at use site inside an `if #available(macOS 15, *)` branch.
- **Both pipelines emit the same `LabeledSegment` type**, so the formatters and the rest of the app remain language-agnostic. The only branch is at the top of `TranscriptionService.transcribe(...)`.

## 2026-03-21 — Add command-line tool target

### What was done

- **Added `transcript` CLI target** — a command-line tool that reuses the 6 core logic files (Models, TranscriptionService, TranscriptMerger, SpeakerClustering, SpeakerEmbedding, OutputGenerator) from the GUI app.
- **Single new file**: `TranscriptCLI/TranscriptCLI.swift` — an `AsyncParsableCommand` using swift-argument-parser.
- **Added swift-argument-parser** (v1.5+) as an SPM dependency, linked only to the CLI target.
- **Usage**: `transcript file1.mp4 file2.mp3 --output /dir --srt --no-speakers`. Status to stderr, output paths to stdout.
- **Added `TranscriptCLI` Xcode scheme** for building the CLI from Xcode.
- **Updated README** with CLI usage examples and architecture showing shared files.

### Design decisions

- **Shared source files, not a library**: the 6 logic files are added to both targets' Sources build phases (separate PBXBuildFile entries pointing to the same PBXFileReference). This avoids the complexity of extracting a framework/library while keeping both targets in sync. Dead code from `Models.swift` (GUI-specific types like `FileItem`, `TranscriptionSettings`) is stripped at link time.

- **ArgumentParser over manual parsing**: the CLI supports variadic files, `--output`, `--no-speakers`, `--txt`, `--srt` — too many flags for reliable manual parsing. ArgumentParser gives free `--help`, validation, and type safety.

- **Product name `transcript` (lowercase)**: CLI convention. The target name in the pbxproj is lowercase to produce a lowercase binary. The scheme is named `TranscriptCLI` to avoid case collision with the `Transcript` app scheme.

- **stderr for status, stdout for paths**: allows piping (`transcript file.mp4 | xargs open`) and scripting while still seeing progress.

## 2026-03-21 — Separate speaker detection, add integration tests with fixture snapshots

### What was done

- **Separated speaker detection into 3 files** with strict dependency boundaries:
  - `SpeakerClustering.swift` — pure math (cosineSim, l2Norm, kMeans, silhouetteScore, clusterConfidence). Only depends on Accelerate. Fully unit-testable.
  - `SpeakerEmbedding.swift` — CoreML model loading + WeSpeaker embedding computation. Depends on CoreML.
  - `TranscriptMerger.swift` — thin orchestrator that converts FluidAudio `TokenTiming` to our own `TimedWord` at the boundary, then delegates to the above.

- **Introduced `TimedWord` struct** in `Models.swift` — our own lightweight type replacing `TokenTiming` (FluidAudio) in all internal processing. This removes the FluidAudio dependency from all testable logic.

- **Made `extractAudioSamples` static** on `TranscriptionService` so integration tests can call it directly without instantiating the full service.

- **Rewrote unit tests** to use new structure:
  - `SpeakerClusteringTests` — 13 tests on pure math (cosineSim, kMeans, silhouetteScore, clusterEmbeddings, clusterConfidence)
  - `TranscriptMergerTests` — 9 tests on token processing using `TimedWord` (splitAtPunctuation, smoothRuns, buildOutput, carryAcrossContinuations)

- **Added integration tests** (`SpeakerIntegrationTests.swift`):
  - `testFixtureAudioExtraction` — validates audio extraction from fixture .m4a
  - `testSpeakerEmbeddingsAreDifferentForDifferentSpeakers` — computes real WeSpeaker embeddings on a fixture, clusters them, asserts 2+ speakers found. Writes `<fixture-name>.json` snapshot for offline non-regression.
  - `testClusteringFromSnapshot` — loads committed `.json` snapshot, re-clusters, asserts consistent results. No CoreML needed.
  - `testFullPipelineTranscriptOutput` — runs full ASR + speaker detection, writes `<fixture-name>.txt`. On subsequent runs, compares output against committed reference.

- **Created shared Xcode scheme** (`Transcript.xcscheme`) so the TranscriptTests target appears in the Test Navigator.

- **Added fixture audio file** (`TranscriptTests/Fixtures/Joe Rogan 2331 - Jesse Michels.m4a`) — ~3 min two-speaker podcast clip for integration testing.

- **Added README.md and THOUGHTS.md to Xcode project** navigator for easy access.

- **Updated README.md** with test instructions (unit tests, integration tests, snapshot generation).

- **Updated THOUGHTS.md** with speaker detection architecture, WeSpeaker origins/references, multi-language analysis, and testing strategy.

### Design decisions

- **`TimedWord` over protocol**: chose a concrete struct over a protocol for the FluidAudio boundary. Simpler, no generics overhead, and `TokenTiming` is the only type we'd ever conform. The conversion happens in one place (`TranscriptMerger.merge()`).

- **Snapshot naming convention**: `.json` and `.txt` snapshots use the same base name as the fixture `.m4a`. This scales naturally — add a new fixture, run the tests, commit the snapshots.

- **No snapshot in bundle resources during build**: the `.json`/`.txt` snapshots are not added to the pbxproj build resources since they may not exist yet on first clone. Tests fall back to reading from the source tree via `#filePath`. Once generated and committed, they're available to all subsequent test runs.

## 2026-03-20 — Harden code: fix force unwraps, add tests, retry logic, document magic numbers

### What was done

- Replaced 5 force unwraps with guard-let + descriptive errors
- Added NSLock for thread-safe asrManager access
- Documented CoreML model constants (frame counts, embedding dimensions)
- Added automatic retry with backoff for model downloads (3 attempts, 2s/4s)
- Added retry button for failed files in the queue UI
- Added 15 unit tests covering clustering, cosine similarity, silhouette scoring, and output generation
- Wrote THOUGHTS.md with honest project assessment
