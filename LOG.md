# Development Log

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
