import XCTest
import AVFoundation
@testable import Transcript

/// Integration tests for the speaker detection pipeline.
///
/// These tests require the WeSpeaker CoreML models to be downloaded
/// (run the app once to trigger the ~100 MB download).
/// The fixture audio is a ~3-minute two-speaker podcast clip.
///
/// The first run generates a JSON snapshot of the computed embeddings
/// alongside the fixture (same name, .json extension) for use in
/// fast offline non-regression tests.
final class SpeakerIntegrationTests: XCTestCase {

    // Fixture audio file name (without extension)
    private let fixtureName = "Joe Rogan 2331 - Jesse Michels"

    private var fixtureURL: URL!
    private var fixturesDir: URL!

    override func setUp() {
        super.setUp()
        let bundle = Bundle(for: type(of: self))
        fixtureURL = bundle.url(forResource: fixtureName, withExtension: "m4a")
        fixturesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// JSON snapshot filename derived from the fixture audio filename.
    private var snapshotName: String { fixtureName + ".json" }

    // MARK: - Audio Extraction

    func testFixtureAudioExtraction() async throws {
        guard let url = fixtureURL else {
            throw XCTSkip("Fixture audio file not found in test bundle")
        }

        let samples = try await TranscriptionService.extractAudioSamples(from: url)

        // ~195 seconds at 16kHz = ~3,120,000 samples
        XCTAssertGreaterThan(samples.count, 2_000_000, "Should have at least 2M samples (~125s)")
        XCTAssertLessThan(samples.count, 4_000_000, "Should have less than 4M samples (~250s)")

        // Audio should not be silence
        let maxAmplitude = samples.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(maxAmplitude, 0.01, "Audio should not be silent")
    }

    // MARK: - Embedding Computation

    func testSpeakerEmbeddingsAreDifferentForDifferentSpeakers() async throws {
        guard let url = fixtureURL else {
            throw XCTSkip("Fixture audio file not found in test bundle")
        }

        let models: SpeakerEmbedding.Models
        do {
            models = try SpeakerEmbedding.loadModels()
        } catch {
            throw XCTSkip("WeSpeaker models not downloaded — run the app once first. Error: \(error)")
        }

        let samples = try await TranscriptionService.extractAudioSamples(from: url)

        // Compute embeddings for 10-second windows across the clip.
        // In a two-speaker podcast, different windows will capture different speakers.
        let windowDuration = 10.0
        let totalDuration = Double(samples.count) / 16000.0
        let windowCount = Int(totalDuration / windowDuration)

        var embeddings: [[Float]] = []
        var timeRanges: [(start: Double, end: Double)] = []

        for i in 0..<min(windowCount, 18) {
            let start = Double(i) * windowDuration
            let end = start + windowDuration

            let emb = try SpeakerEmbedding.computeEmbedding(
                models: models,
                audioSamples: samples,
                startTime: start,
                endTime: end
            )
            embeddings.append(emb)
            timeRanges.append((start: start, end: end))
        }

        XCTAssertGreaterThanOrEqual(embeddings.count, 6, "Should have at least 6 embeddings")

        // All embeddings should be 256-dim and L2-normalized
        for (i, emb) in embeddings.enumerated() {
            XCTAssertEqual(emb.count, 256, "Embedding \(i) should be 256-dim")
            let norm = SpeakerClustering.l2Norm(emb)
            XCTAssertEqual(norm, 1.0, accuracy: 0.01, "Embedding \(i) should be L2-normalized")
        }

        // Cluster the embeddings — should find 2 speakers
        let (labels, k) = SpeakerClustering.clusterEmbeddings(embeddings, maxSpeakers: 6)
        XCTAssertGreaterThanOrEqual(k, 2, "Should detect at least 2 speakers in a podcast")
        XCTAssertLessThanOrEqual(k, 4, "Should not detect more than 4 speakers")

        // Both clusters should have at least 2 segments each
        let clusterCounts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        for (cluster, count) in clusterCounts {
            XCTAssertGreaterThanOrEqual(count, 2, "Cluster \(cluster) should have at least 2 segments")
        }

        // Intra-cluster similarity should be higher than inter-cluster
        let silhouette = SpeakerClustering.silhouetteScore(embeddings, labels: labels)
        XCTAssertGreaterThan(silhouette, 0.0, "Silhouette score should be positive for real speakers")

        // --- Generate JSON snapshot for offline non-regression testing ---
        try writeSnapshot(
            embeddings: embeddings,
            timeRanges: timeRanges,
            labels: labels,
            k: k,
            silhouette: silhouette
        )
    }

    // MARK: - Non-Regression from Snapshot
    //
    // Uses pre-computed embeddings from <fixture-name>.json.
    // The JSON should be committed to TranscriptTests/Fixtures/ so that
    // clustering non-regression runs without CoreML models.
    // To regenerate: run testSpeakerEmbeddingsAreDifferentForDifferentSpeakers.

    func testClusteringFromSnapshot() throws {
        // Try source tree first (local dev), then test bundle (CI)
        let candidates = [
            fixturesDir.appendingPathComponent(snapshotName),
            Bundle(for: type(of: self)).url(forResource: fixtureName, withExtension: "json")
        ].compactMap { $0 }

        guard let snapshotURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("No snapshot \(snapshotName) found — run testSpeakerEmbeddingsAreDifferentForDifferentSpeakers first to generate it, then commit the JSON")
        }

        let data = try Data(contentsOf: snapshotURL)
        let snapshot = try JSONDecoder().decode(EmbeddingsSnapshot.self, from: data)

        // Re-cluster from saved embeddings — should produce consistent results
        let (labels, k) = SpeakerClustering.clusterEmbeddings(snapshot.embeddings, maxSpeakers: 6)
        XCTAssertGreaterThanOrEqual(k, 2)
        XCTAssertLessThanOrEqual(k, 4)

        let silhouette = SpeakerClustering.silhouetteScore(snapshot.embeddings, labels: labels)
        XCTAssertGreaterThan(silhouette, 0.0)

        // Silhouette should be in the same ballpark as when snapshot was generated
        XCTAssertEqual(silhouette, snapshot.silhouette, accuracy: 0.2,
            "Clustering should produce similar quality to original")
    }

    // MARK: - Full Pipeline Transcript Output
    //
    // Runs ASR + speaker detection on the fixture, writes <fixture-name>.txt,
    // and compares against the committed reference on subsequent runs.
    // To regenerate: delete the .txt from Fixtures/ and re-run.

    func testFullPipelineTranscriptOutput() async throws {
        guard let url = fixtureURL else {
            throw XCTSkip("Fixture audio file not found in test bundle")
        }

        let txtPath = fixturesDir.path + "/" + fixtureName + ".txt"
        let referenceExists = FileManager.default.fileExists(atPath: txtPath)

        // Run the full transcription pipeline
        let service = TranscriptionService()
        let result = try await service.transcribe(
            fileURL: url,
            outputDir: URL(fileURLWithPath: fixturesDir.path),
            txtEnabled: true,
            srtEnabled: false,
            speakerDetection: true
        ) { update in
            if case .log(let msg) = update.kind {
                print(msg)
            }
        }

        guard let outputPath = result.txtPath else {
            XCTFail("Transcription produced no .txt output")
            return
        }

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        XCTAssertFalse(output.isEmpty, "Transcript should not be empty")
        XCTAssertTrue(output.contains("Speaker A"), "Transcript should contain speaker labels")

        if referenceExists {
            // Non-regression: compare against committed reference
            let reference = try String(contentsOfFile: txtPath, encoding: .utf8)
            XCTAssertEqual(output, reference,
                "Transcript output changed — if intentional, delete \(fixtureName).txt from Fixtures/ and re-run to update the reference")
        } else {
            // First run: the file was written by TranscriptionService to the Fixtures dir
            print("Wrote reference transcript: \(outputPath)")
        }
    }

    // MARK: - Snapshot I/O

    private struct EmbeddingsSnapshot: Codable {
        let embeddings: [[Float]]
        let timeRanges: [TimeRange]
        let labels: [Int]
        let k: Int
        let silhouette: Double

        struct TimeRange: Codable {
            let start: Double
            let end: Double
        }
    }

    private func writeSnapshot(
        embeddings: [[Float]],
        timeRanges: [(start: Double, end: Double)],
        labels: [Int],
        k: Int,
        silhouette: Double
    ) throws {
        let snapshot = EmbeddingsSnapshot(
            embeddings: embeddings,
            timeRanges: timeRanges.map { .init(start: $0.start, end: $0.end) },
            labels: labels,
            k: k,
            silhouette: silhouette
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)

        let outputPath = fixturesDir.path + "/" + snapshotName
        try data.write(to: URL(fileURLWithPath: outputPath))

        print("Wrote snapshot: \(outputPath)")
        print("  \(embeddings.count) embeddings, k=\(k), silhouette=\(String(format: "%.4f", silhouette))")
    }
}
