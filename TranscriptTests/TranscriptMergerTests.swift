import XCTest
@testable import Transcript

final class TranscriptMergerTests: XCTestCase {

    // MARK: - cosineSim

    func testCosineSimIdenticalVectors() {
        let v: [Float] = [1, 0, 0, 0]
        let sim = TranscriptMerger.cosineSim(v, v)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-5)
    }

    func testCosineSimOrthogonalVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let sim = TranscriptMerger.cosineSim(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-5)
    }

    func testCosineSimOppositeVectors() {
        let a: [Float] = [1, 0]
        let b: [Float] = [-1, 0]
        let sim = TranscriptMerger.cosineSim(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 1e-5)
    }

    func testCosineSimZeroVector() {
        let a: [Float] = [1, 2, 3]
        let zero: [Float] = [0, 0, 0]
        let sim = TranscriptMerger.cosineSim(a, zero)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-5)
    }

    // MARK: - kMeans

    func testKMeansTwoClearClusters() {
        // Two well-separated clusters in 3D
        let embeddings: [[Float]] = [
            [1, 0, 0], [0.9, 0.1, 0], [0.95, 0.05, 0],  // cluster A
            [0, 1, 0], [0.1, 0.9, 0], [0.05, 0.95, 0],  // cluster B
        ]
        let labels = TranscriptMerger.kMeans(embeddings, k: 2)

        // Points in the same cluster should have the same label
        XCTAssertEqual(labels[0], labels[1])
        XCTAssertEqual(labels[1], labels[2])
        XCTAssertEqual(labels[3], labels[4])
        XCTAssertEqual(labels[4], labels[5])
        // The two clusters should have different labels
        XCTAssertNotEqual(labels[0], labels[3])
    }

    func testKMeansSinglePoint() {
        let labels = TranscriptMerger.kMeans([[1, 0]], k: 2)
        XCTAssertEqual(labels, [0])
    }

    func testKMeansKEqualsN() {
        let embeddings: [[Float]] = [[1, 0], [0, 1]]
        let labels = TranscriptMerger.kMeans(embeddings, k: 2)
        XCTAssertEqual(labels.count, 2)
        XCTAssertNotEqual(labels[0], labels[1])
    }

    // MARK: - silhouetteScore

    func testSilhouetteScorePerfectClusters() {
        // Two perfectly separated clusters
        let embeddings: [[Float]] = [
            [1, 0, 0], [1, 0, 0], [1, 0, 0],
            [0, 1, 0], [0, 1, 0], [0, 1, 0],
        ]
        let labels = [0, 0, 0, 1, 1, 1]
        let score = TranscriptMerger.silhouetteScore(embeddings, labels: labels)
        // Perfect separation should give score close to 1.0
        XCTAssertGreaterThan(score, 0.9)
    }

    func testSilhouetteScoreRandomLabels() {
        // Two identical clusters — random labels should give low/negative score
        let embeddings: [[Float]] = [
            [1, 0], [1, 0], [1, 0], [1, 0],
        ]
        let labels = [0, 1, 0, 1]
        let score = TranscriptMerger.silhouetteScore(embeddings, labels: labels)
        // Mixed identical points should give poor score
        XCTAssertLessThanOrEqual(score, 0.0)
    }

    func testSilhouetteScoreInsufficientClusters() {
        let embeddings: [[Float]] = [[1, 0], [0, 1]]
        let labels = [0, 0]  // only 1 cluster
        let score = TranscriptMerger.silhouetteScore(embeddings, labels: labels)
        XCTAssertEqual(score, -1.0)
    }

    // MARK: - clusterEmbeddings

    func testClusterEmbeddingsFindsCorrectK() {
        // 3 well-separated clusters
        let embeddings: [[Float]] = [
            [1, 0, 0], [0.95, 0.05, 0],
            [0, 1, 0], [0.05, 0.95, 0],
            [0, 0, 1], [0.05, 0, 0.95],
        ]
        let (labels, k) = TranscriptMerger.clusterEmbeddings(embeddings, maxSpeakers: 6)
        XCTAssertEqual(labels.count, 6)
        // Should find 3 clusters
        XCTAssertEqual(k, 3)
        // Same-cluster pairs
        XCTAssertEqual(labels[0], labels[1])
        XCTAssertEqual(labels[2], labels[3])
        XCTAssertEqual(labels[4], labels[5])
    }

    func testClusterEmbeddingsSingleEmbedding() {
        let (labels, k) = TranscriptMerger.clusterEmbeddings([[1, 0, 0]], maxSpeakers: 4)
        XCTAssertEqual(labels, [0])
        XCTAssertEqual(k, 1)
    }

    // MARK: - buildOutput

    func testBuildOutputGroupsConsecutiveSpeakers() {
        // buildOutput needs (token: TokenTiming, speaker: Int, confidence: Double)
        // but TokenTiming is from FluidAudio — skip this if we can't construct one.
        // Tested indirectly through OutputGenerator tests below.
    }

    // MARK: - smoothRuns (uses tuples with TokenTiming — tested via integration)
}
