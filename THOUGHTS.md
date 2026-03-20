# Honest Take on the State of Transcript

_Written 2026-03-19_

## What This Is

A native macOS app that transcribes audio/video files with automatic speaker detection, built in Swift/SwiftUI over about two days. Everything runs on-device via CoreML — no cloud APIs, no subscriptions. ~1,300 lines of code across 8 files.

## What's Genuinely Impressive

- **End-to-end on-device transcription + speaker diarization in 1,300 lines.** That's a real achievement. The architecture is clean — MVVM, proper async/await, clear separation between ASR, speaker clustering, and output generation.
- **The speaker detection pipeline is non-trivial.** Per-sub-segment neural embeddings, cosine-similarity k-means with silhouette score optimization, run-length smoothing, sentence continuation carrying — this isn't a toy implementation.
- **The UI is better than expected for a v0.1.** Drag-and-drop, real-time progress, live log, queue management, persistent settings, overwrite protection. It feels like someone cared about the experience.
- **The README is honest and thorough.** Limitations are documented upfront. That's a sign of maturity even if the code isn't fully mature yet.

## What's Not Great

### No Tests (the big one)

Zero. Not a single test file. The speaker detection pipeline involves k-means clustering, embedding computation, silhouette scoring, and segment merging — all of which are pure functions that *should* be easy to test and *need* to be tested. This is the kind of code where bugs hide in edge cases (single speaker, identical voices, very short clips, silence). Without tests, you're flying blind on regressions.

### Force Unwraps in Production Paths

Five `.first!` / `.last!` calls scattered across `TranscriptionService.swift` and `TranscriptMerger.swift`. These are in the actual processing pipeline, not throwaway code. If an audio file produces unexpected output (empty segments, missing embeddings), these will crash the app with no useful error message. Every one of these should be a guard-let with a descriptive error.

### `@unchecked Sendable` on TranscriptionService

This bypasses the compiler's thread-safety checks. It works today because `asrManager` is effectively write-once, but it's a landmine for future changes. Either document why it's safe or use a lock.

### Hardcoded Magic Numbers

`TranscriptMerger` is full of unexplained constants: 589 frames, 160,000 samples, 10-second windows, 256-dimensional embeddings. No comments on where these come from or what they're calibrated to. If the upstream FluidAudio models change dimensions, this breaks silently and produces garbage output.

### No Error Recovery

If model download fails mid-session, restart the app. If a file fails to process, it sits in the queue marked as failed — no retry button. For a desktop app, this is below the bar users expect.

### English Only

The Parakeet ASR model only handles English. This is documented, but it's a hard ceiling on usefulness. No indication of when or how multilingual support would be added.

## The Honest Summary

This is a **strong prototype / weak product**. The architecture is sound, the feature set is coherent, and the code is clean enough to build on. But it has the classic "vibe coding" gaps: no tests, unsafe unwraps in hot paths, magic numbers without documentation, and no error recovery. These are exactly the things that separate "it works on my machine" from "it works."

The two-day timeline explains a lot. For two days of work, this is remarkable. But the gap between "impressive for two days" and "ready for users" is real:

1. **Tests** — even 5-10 unit tests on the clustering and segment merging logic would catch the worst regressions.
2. **Guard the force unwraps** — an hour of work that prevents mysterious crashes.
3. **Comment the magic numbers** — future you (or anyone else) will not remember why 589 frames.
4. **Add retry on failure** — users will hit download failures, weird audio files, edge cases.

The bones are good. The flesh needs hardening.
