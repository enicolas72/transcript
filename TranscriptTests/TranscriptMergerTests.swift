import XCTest
@testable import Transcript

// MARK: - Clustering Tests (pure math, no external deps)

final class SpeakerClusteringTests: XCTestCase {

    // MARK: - cosineSim

    func testCosineSimIdenticalVectors() {
        let v: [Float] = [1, 0, 0, 0]
        XCTAssertEqual(SpeakerClustering.cosineSim(v, v), 1.0, accuracy: 1e-5)
    }

    func testCosineSimOrthogonalVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        XCTAssertEqual(SpeakerClustering.cosineSim(a, b), 0.0, accuracy: 1e-5)
    }

    func testCosineSimOppositeVectors() {
        let a: [Float] = [1, 0]
        let b: [Float] = [-1, 0]
        XCTAssertEqual(SpeakerClustering.cosineSim(a, b), -1.0, accuracy: 1e-5)
    }

    func testCosineSimZeroVector() {
        let a: [Float] = [1, 2, 3]
        let zero: [Float] = [0, 0, 0]
        XCTAssertEqual(SpeakerClustering.cosineSim(a, zero), 0.0, accuracy: 1e-5)
    }

    // MARK: - kMeans

    func testKMeansTwoClearClusters() {
        let embeddings: [[Float]] = [
            [1, 0, 0], [0.9, 0.1, 0], [0.95, 0.05, 0],
            [0, 1, 0], [0.1, 0.9, 0], [0.05, 0.95, 0],
        ]
        let labels = SpeakerClustering.kMeans(embeddings, k: 2)

        XCTAssertEqual(labels[0], labels[1])
        XCTAssertEqual(labels[1], labels[2])
        XCTAssertEqual(labels[3], labels[4])
        XCTAssertEqual(labels[4], labels[5])
        XCTAssertNotEqual(labels[0], labels[3])
    }

    func testKMeansSinglePoint() {
        let labels = SpeakerClustering.kMeans([[1, 0]], k: 2)
        XCTAssertEqual(labels, [0])
    }

    func testKMeansKEqualsN() {
        let embeddings: [[Float]] = [[1, 0], [0, 1]]
        let labels = SpeakerClustering.kMeans(embeddings, k: 2)
        XCTAssertEqual(labels.count, 2)
        XCTAssertNotEqual(labels[0], labels[1])
    }

    // MARK: - silhouetteScore

    func testSilhouetteScorePerfectClusters() {
        let embeddings: [[Float]] = [
            [1, 0, 0], [1, 0, 0], [1, 0, 0],
            [0, 1, 0], [0, 1, 0], [0, 1, 0],
        ]
        let labels = [0, 0, 0, 1, 1, 1]
        let score = SpeakerClustering.silhouetteScore(embeddings, labels: labels)
        XCTAssertGreaterThan(score, 0.9)
    }

    func testSilhouetteScoreRandomLabels() {
        let embeddings: [[Float]] = [
            [1, 0], [1, 0], [1, 0], [1, 0],
        ]
        let labels = [0, 1, 0, 1]
        let score = SpeakerClustering.silhouetteScore(embeddings, labels: labels)
        XCTAssertLessThanOrEqual(score, 0.0)
    }

    func testSilhouetteScoreInsufficientClusters() {
        let embeddings: [[Float]] = [[1, 0], [0, 1]]
        let labels = [0, 0]
        let score = SpeakerClustering.silhouetteScore(embeddings, labels: labels)
        XCTAssertEqual(score, -1.0)
    }

    // MARK: - clusterEmbeddings

    func testClusterEmbeddingsFindsCorrectK() {
        let embeddings: [[Float]] = [
            [1, 0, 0], [0.95, 0.05, 0],
            [0, 1, 0], [0.05, 0.95, 0],
            [0, 0, 1], [0.05, 0, 0.95],
        ]
        let (labels, k) = SpeakerClustering.clusterEmbeddings(embeddings, maxSpeakers: 6)
        XCTAssertEqual(labels.count, 6)
        XCTAssertEqual(k, 3)
        XCTAssertEqual(labels[0], labels[1])
        XCTAssertEqual(labels[2], labels[3])
        XCTAssertEqual(labels[4], labels[5])
    }

    func testClusterEmbeddingsSingleEmbedding() {
        let (labels, k) = SpeakerClustering.clusterEmbeddings([[1, 0, 0]], maxSpeakers: 4)
        XCTAssertEqual(labels, [0])
        XCTAssertEqual(k, 1)
    }

    // MARK: - clusterConfidence

    func testClusterConfidenceSingleCluster() {
        let emb: [Float] = [1, 0, 0]
        let all: [[Float]] = [[1, 0, 0], [0.9, 0.1, 0]]
        let labels = [0, 0]
        let conf = SpeakerClustering.clusterConfidence(emb, allEmbeddings: all, labels: labels)
        XCTAssertEqual(conf, 1.0)
    }
}

// MARK: - Token Processing Tests (uses TimedWord — no FluidAudio needed)

final class TranscriptMergerTests: XCTestCase {

    private func word(_ text: String, start: Double, end: Double) -> TimedWord {
        TimedWord(word: text, startTime: start, endTime: end)
    }

    // MARK: - splitAtPunctuation

    func testSplitAtPunctuationBasic() {
        let words = [
            word(" Hello", start: 0, end: 0.5),
            word(" world", start: 0.5, end: 1.0),
            word(" today.", start: 1.0, end: 1.5),
            word(" How", start: 1.5, end: 2.0),
            word(" are", start: 2.0, end: 2.5),
            word(" you?", start: 2.5, end: 3.0),
        ]
        let subs = TranscriptMerger.splitAtPunctuation(words)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].count, 3)
        XCTAssertEqual(subs[1].count, 3)
    }

    func testSplitAtPunctuationNoPunctuation() {
        let words = [
            word(" Hello", start: 0, end: 0.5),
            word(" world", start: 0.5, end: 1.0),
        ]
        let subs = TranscriptMerger.splitAtPunctuation(words)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].count, 2)
    }

    func testSplitAtPunctuationRespectsMinWords() {
        // Two words then period — below minWords=3, shouldn't split
        let words = [
            word(" Hi", start: 0, end: 0.3),
            word(" there.", start: 0.3, end: 0.6),
            word(" How", start: 0.6, end: 0.9),
            word(" are", start: 0.9, end: 1.2),
            word(" you?", start: 1.2, end: 1.5),
        ]
        let subs = TranscriptMerger.splitAtPunctuation(words)
        // "Hi there." is only 2 words, so it shouldn't split there
        // All 5 words should end up together since the first potential
        // split point has < 3 words
        XCTAssertEqual(subs.count, 1)
    }

    func testSplitAtPunctuationEmpty() {
        let subs = TranscriptMerger.splitAtPunctuation([])
        XCTAssertEqual(subs.count, 1)
        XCTAssertTrue(subs[0].isEmpty)
    }

    // MARK: - smoothRuns

    func testSmoothRunsAbsorbsShortRuns() {
        let words = (0..<10).map { i in word(" w\(i)", start: Double(i), end: Double(i + 1)) }
        var labeled = words.map { (word: $0, speaker: 0, confidence: 0.9) }
        // Insert a short run of speaker 1 in the middle (2 words, below minRun=5)
        labeled[4].speaker = 1
        labeled[5].speaker = 1

        let smoothed = TranscriptMerger.smoothRuns(labeled, minRun: 5)
        let speakers = smoothed.map(\.speaker)
        // Short run should be absorbed into surrounding speaker 0
        XCTAssertTrue(speakers.allSatisfy { $0 == 0 })
    }

    func testSmoothRunsKeepsLongRuns() {
        let words = (0..<10).map { i in word(" w\(i)", start: Double(i), end: Double(i + 1)) }
        var labeled = words.map { (word: $0, speaker: 0, confidence: 0.9) }
        // Speaker 1 for 5 words (meets minRun=5)
        for i in 5..<10 { labeled[i].speaker = 1 }

        let smoothed = TranscriptMerger.smoothRuns(labeled, minRun: 5)
        XCTAssertEqual(smoothed[0].speaker, 0)
        XCTAssertEqual(smoothed[9].speaker, 1)
    }

    // MARK: - buildOutput

    func testBuildOutputGroupsBySpeaker() {
        let words = [
            word(" Hello", start: 0, end: 0.5),
            word(" world", start: 0.5, end: 1.0),
            word(" Hi", start: 1.0, end: 1.5),
            word(" there", start: 1.5, end: 2.0),
        ]
        let labeled: [(word: TimedWord, speaker: Int, confidence: Double)] = [
            (word: words[0], speaker: 0, confidence: 0.9),
            (word: words[1], speaker: 0, confidence: 0.9),
            (word: words[2], speaker: 1, confidence: 0.8),
            (word: words[3], speaker: 1, confidence: 0.8),
        ]
        let segments = TranscriptMerger.buildOutput(labeled)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "Speaker A")
        XCTAssertEqual(segments[1].speaker, "Speaker B")
        XCTAssertEqual(segments[0].text, "Hello world")
        XCTAssertEqual(segments[1].text, "Hi there")
    }

    func testBuildOutputSingleSpeaker() {
        let words = [
            word(" One", start: 0, end: 0.5),
            word(" two", start: 0.5, end: 1.0),
        ]
        let labeled: [(word: TimedWord, speaker: Int, confidence: Double)] = [
            (word: words[0], speaker: 0, confidence: 1.0),
            (word: words[1], speaker: 0, confidence: 1.0),
        ]
        let segments = TranscriptMerger.buildOutput(labeled)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speaker, "Speaker A")
    }

    func testBuildOutputPreservesTimestamps() {
        let words = [
            word(" Start", start: 1.5, end: 2.0),
            word(" end", start: 2.0, end: 3.5),
        ]
        let labeled: [(word: TimedWord, speaker: Int, confidence: Double)] = [
            (word: words[0], speaker: 0, confidence: 1.0),
            (word: words[1], speaker: 0, confidence: 1.0),
        ]
        let segments = TranscriptMerger.buildOutput(labeled)
        XCTAssertEqual(segments[0].start, 1.5)
        XCTAssertEqual(segments[0].end, 3.5)
    }

    // MARK: - carryAcrossContinuations

    func testCarryAcrossContinuationsAtPunctuation() {
        // Sub 1 ends with period → sub 2 should NOT be carried
        let words = [
            word(" Hello.", start: 0, end: 0.5),
            word(" World", start: 0.5, end: 1.0),
            word(" here", start: 1.0, end: 1.5),
            word(" now.", start: 1.5, end: 2.0),
        ]
        let subs = [
            [words[0]],
            [words[1], words[2], words[3]],
        ]
        let labeled: [(word: TimedWord, speaker: Int, confidence: Double)] = [
            (word: words[0], speaker: 0, confidence: 0.9),
            (word: words[1], speaker: 1, confidence: 0.5),
            (word: words[2], speaker: 1, confidence: 0.5),
            (word: words[3], speaker: 1, confidence: 0.5),
        ]
        let result = TranscriptMerger.carryAcrossContinuations(labeled, subs: subs)
        // Sub 1 ended with "." so speaker 1 should NOT be overridden
        XCTAssertEqual(result[1].speaker, 1)
    }
}
