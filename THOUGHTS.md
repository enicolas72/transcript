# Honest Take on the State of Transcript

_Written 2026-03-19_

## What This Is

A native macOS app that transcribes audio/video files with automatic speaker detection, built in Swift/SwiftUI over about two days. Everything runs on-device via CoreML — no cloud APIs, no subscriptions. ~1,300 lines of code across 8 files.

## What's Genuinely Impressive

- **End-to-end on-device transcription + speaker diarization in 1,300 lines.** That's a real achievement. The architecture is clean — MVVM, proper async/await, clear separation between ASR, speaker clustering, and output generation.
- **The speaker detection pipeline is non-trivial.** Per-sub-segment neural embeddings, cosine-similarity k-means with silhouette score optimization, run-length smoothing, sentence continuation carrying — this isn't a toy implementation.
- **The UI is better than expected for a v0.1.** Drag-and-drop, real-time progress, live log, queue management, persistent settings, overwrite protection. It feels like someone cared about the experience.
- **The README is honest and thorough.** Limitations are documented upfront. That's a sign of maturity even if the code isn't fully mature yet.

## What's Been Fixed (2026-03-20)

### Tests — added (was: zero)

15 unit tests now cover the core algorithm layer: cosine similarity (4 tests including edge cases like zero vectors), k-means clustering (3 tests: clear separation, single point, k=n), silhouette scoring (3 tests: perfect clusters, random labels, degenerate input), cluster embedding selection (2 tests), and output generation (4 tests on speaker-labeled text formatting). The pure algorithm functions on `TranscriptMerger` were changed from `private` to `internal` to enable `@testable import`. A proper `TranscriptTests` Xcode target was added to the project.

Still not tested: anything involving `TokenTiming` (FluidAudio type), the full `merge()` pipeline end-to-end, audio extraction, or model loading. Those would require either mocking FluidAudio or integration tests with real audio files.

### Force unwraps — all 5 replaced

Every `.first!` / `.last!` in the processing pipeline now uses `guard let` with a descriptive error or `continue`. No more silent crashes on unexpected input.

### `@unchecked Sendable` — documented and locked

`TranscriptionService` now uses an `NSLock` for thread-safe `asrManager` access. The `@unchecked Sendable` remains (because `NSLock` itself isn't `Sendable`-friendly in Swift's strict concurrency model), but the actual thread safety is now enforced rather than assumed.

### Magic numbers — documented

All CoreML model constants (`160,000` samples, `589` mask frames, `998` FBank frames, `256`-dim embeddings) now have comments explaining what they are, where they come from (WeSpeaker ResNet34, FBank model architecture), and a warning not to change them unless the upstream `.mlmodelc` files change.

### Error recovery — retry added

Model downloads now automatically retry up to 3 times with exponential backoff (2s, 4s), with user-visible log messages on each attempt. Failed files in the queue now show an orange retry button in the UI, letting users re-queue without restarting the app.

## What's Still Not Great

### Test coverage is a start, not a finish

See "Testing strategy" section below for the full plan.

### No performance testing

Unknown behavior on very long files (10+ hours). The speaker detection pipeline processes the entire audio — no streaming or progressive approach. This could be slow or memory-intensive for large inputs.

## Speaker Detection Architecture (refactored 2026-03-21)

Speaker detection is now separated into three files with strict dependency boundaries:

| File | Responsibility | Dependencies | Testable without models? |
|------|---------------|-------------|-------------------------|
| `SpeakerClustering.swift` | Pure math: cosineSim, l2Norm, kMeans, silhouetteScore, clusterConfidence, clusterEmbeddings | Accelerate only | Yes — fully |
| `SpeakerEmbedding.swift` | CoreML model loading + embedding computation (FBank → WeSpeaker ResNet34) | CoreML, SpeakerClustering | No — requires .mlmodelc files |
| `TranscriptMerger.swift` | Orchestrator: splits tokens, calls embedding + clustering, post-processes labels | FluidAudio (TokenTiming), SpeakerEmbedding, SpeakerClustering | Partially — all internal functions use `TimedWord` |

The key design decision: **`TimedWord`** (defined in `Models.swift`) is our own lightweight struct with `word`, `startTime`, `endTime`. `TranscriptMerger.merge()` converts FluidAudio's `TokenTiming` → `TimedWord` at the boundary, then all internal processing uses `TimedWord`. This means `splitAtPunctuation`, `carryAcrossContinuations`, `smoothRuns`, and `buildOutput` can all be tested by constructing `TimedWord` values directly — no FluidAudio import needed in tests.

## Speaker Detection Details

The speaker detection pipeline relies on WeSpeaker, a speaker embedding model — it takes a chunk of audio and produces a 256-dimensional vector that represents *who is speaking*, not *what they're saying*. Two clips of the same person produce similar vectors; two different people produce distant vectors. The project uses WeSpeaker's ResNet34 architecture, converted to CoreML. The pipeline in `TranscriptMerger.swift` works in three stages: first a FBank model converts raw 16kHz audio into a mel-frequency filterbank spectrogram (998 frames for 10s of audio), then the WeSpeaker Embedding model turns that spectrogram into a 256-dim speaker identity vector, and finally k-means clustering groups those embeddings to figure out how many speakers there are and which segments belong to which. WeSpeaker is language-agnostic — it models vocal characteristics (pitch, timbre, resonance), not words. It works the same whether the speaker is talking in English, French, or Mandarin.

**Origins and references:**

WeSpeaker was created at **Shanghai Jiao Tong University (SJTU)** by the AudioCC Lab (Prof. Yanmin Qian). It is part of the **wenet-e2e** open-source ecosystem, alongside WeNet (ASR) and WeSep (speaker extraction).

The ResNet34 variant used here is an **r-vector** architecture: a standard ResNet34 backbone processing frame-level FBank features, followed by attentive statistics pooling (ASTP) to produce a fixed 256-dim embedding. The pretrained model (`wespeaker-voxceleb-resnet34-LM`) was trained on VoxCeleb2 Dev (5,994 speakers) with large-margin fine-tuning. It is also the default speaker embedding model in pyannote.audio's `speaker-diarization-3.1` pipeline.

- GitHub: https://github.com/wenet-e2e/wespeaker
- ICASSP 2023 paper: https://arxiv.org/abs/2210.17016
- Pretrained model: https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM

## Multi-Language (added 2026-04-07)

The project now supports French, German, Spanish, Italian, Portuguese, Dutch, Russian, Chinese, Japanese, Korean (and an `auto` mode) in addition to English. There are **two pipelines** internally, selected by language:

### English: Parakeet pipeline (unchanged)

NVIDIA Parakeet TDT 0.6B via FluidAudio. Returns word-level `TokenTiming`s. The existing flow runs: ASR → split tokens at sentence punctuation → embed each sub-segment with WeSpeaker → cosine k-means → smoothing → output. This is the most accurate path because speaker boundaries are word-aligned.

### Non-English: Qwen3-ASR pipeline (new, macOS 15+)

Qwen3-ASR is a decoder-only multilingual ASR by Alibaba/Qwen, wrapped by FluidAudio. It supports 30+ languages (English name passed as a hint, or `nil` for automatic detection) and runs entirely on-device via CoreML. **Critically, it returns no word-level timestamps** — only a transcribed string per call. That single fact forces a different architecture.

The pipeline is **inverted** relative to English: diarize first, then transcribe per turn.

1. **Audio-driven diarization** (`SpeakerDiarizer` in `SpeakerEmbedding.swift`). Slide a 2-second non-overlapping window over the raw 16 kHz audio. For each window, compute a WeSpeaker embedding (the existing FBank → ResNet34 path). Cluster the embeddings with the same `SpeakerClustering.clusterEmbeddings` used by English (silhouette-scored automatic k). Smooth short runs. Merge consecutive same-speaker windows into `Turn(start, end, speaker)` records.
2. **Per-turn ASR.** For each turn, slice the audio buffer and call `Qwen3AsrManager.transcribe(audioSamples:language:)`. The returned text is *the* speaker-correct text for that turn — no alignment guessing required, because each turn was a single ASR call. Skip turns shorter than 0.3 s; drop empty results.
3. **Output.** Build `[LabeledSegment]` directly from `(start, end, text, speaker)`. The TXT output uses the same `generateTXTWithSpeakers` as English. The SRT output is turn-level (one cue per turn) — there are no word timestamps to subdivide further.

When speaker detection is off in the non-English path, the whole file is treated as a single anonymous turn → one Qwen3 call → plain text out.

**Why diarize-first instead of transcribe-then-align?** Because Qwen3 gives us no timing at all. The only alternative would be to call Qwen3 once on the whole file and proportionally distribute characters back to diarized intervals by duration — which is fast but introduces alignment guesswork at every turn boundary. Per-turn ASR is slower (one encoder pass per turn vs. one for the whole file) but it's structurally accurate.

**Trade-offs:**

- **Wall-clock cost.** A 60-min file with ~40 turns runs ~40 separate Qwen3 calls. Significantly slower than the English single-pass.
- **Cue granularity.** SRT cues are turn-level (typically a few seconds to a minute). Fine for chapter-style subtitles, not for word-by-word karaoke.
- **Model size.** Qwen3-ASR `.f32` is ~1.75 GB on disk (downloaded once). An `.int8` variant exists (~900 MB) and could be made user-selectable.
- **Boundary smoothing.** WeSpeaker windows are 2 s, so speaker change points are quantized to that grid in the worst case. The run-length smoother removes 1-window outliers.

The boundary between the two pipelines lives in `TranscriptionService.transcribe(...)`: a single `if language.usesParakeet` switch. Both backends share the same `LabeledSegment` output type and the same WeSpeaker embedding code, so the rest of the app (formatters, UI, CLI flag plumbing) is language-agnostic.

## Testing Strategy

With the separation in place, the speaker detection pipeline can now be tested at three levels:

### Level 1: Pure math (done — no external deps)

`SpeakerClusteringTests` covers cosineSim, kMeans, silhouetteScore, clusterEmbeddings, and clusterConfidence with synthetic embeddings. These tests run instantly, need no models or audio files, and catch regressions in the core clustering logic. Currently 13 tests.

### Level 2: Token processing (done — uses TimedWord, no FluidAudio)

`TranscriptMergerTests` covers splitAtPunctuation, smoothRuns, buildOutput, and carryAcrossContinuations by constructing `TimedWord` values directly. These test the label assignment and post-processing logic without needing real ASR output. Currently 9 tests.

### Level 3: Embedding + full pipeline (not yet done — needs real models)

This is the remaining gap. Two approaches:

**Option A: Fixture-based integration tests.** Record a short (~10s) two-speaker audio file, commit it as a test fixture in `TranscriptTests/Fixtures/`. The test would:
1. Load the fixture audio as `[Float]` samples
2. Call `SpeakerEmbedding.computeEmbedding()` on known time ranges
3. Assert the embeddings for the same speaker are more similar than for different speakers
4. Call the full `TranscriptMerger.merge()` pipeline and assert it finds 2 speakers

Pros: tests the real CoreML path. Cons: requires the WeSpeaker models to be downloaded (slow first run, ~100 MB), fixture file adds to repo size.

**Option B: Snapshot embeddings.** Run the embedding computation once on a fixture, save the resulting `[[Float]]` embeddings as a JSON file. Then tests load the pre-computed embeddings and test clustering + post-processing without touching CoreML at all.

Pros: fast, no model download needed. Cons: doesn't test the CoreML path itself — if the model changes, the snapshots go stale.

**Recommendation:** Do both. Option B for CI (fast, deterministic). Option A as a manual/nightly test gated behind a `SPEAKER_INTEGRATION_TESTS` environment variable.

## The Updated Summary

The project has moved from **strong prototype / weak product** to **solid early release**. The architecture was always sound; now the safety net is catching up. Force unwraps are gone, magic numbers are explained, failures are recoverable, and the core algorithms have regression coverage.

What remains is the kind of work that separates "solid" from "confident": deeper test coverage, performance profiling on large files, and multilingual support. The bones are good, and the flesh is firming up.
