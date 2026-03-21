# Development Log

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
