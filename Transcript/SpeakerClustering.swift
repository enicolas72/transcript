import Foundation
import Accelerate

/// Pure clustering algorithms for speaker diarization.
/// No external dependencies beyond Accelerate — fully unit-testable.
enum SpeakerClustering {

    // MARK: - Vector Math

    static func cosineSim(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    static func l2Norm(_ v: [Float]) -> Float {
        var sum: Float = 0
        vDSP_dotpr(v, 1, v, 1, &sum, vDSP_Length(v.count))
        return sqrt(sum)
    }

    // MARK: - k-Means (cosine similarity)

    static func kMeans(_ embeddings: [[Float]], k: Int, maxIter: Int = 30) -> [Int] {
        let n = embeddings.count
        let dim = embeddings[0].count
        guard n >= k else { return Array(0..<n) }

        // Initialize centroids: first point + farthest points
        var centroids = [embeddings[0]]
        for _ in 1..<k {
            var maxDist = -Float.infinity
            var farthest = 0
            for i in 0..<n {
                let minDist = centroids.map { 1.0 - cosineSim(embeddings[i], $0) }.min()!
                if minDist > maxDist {
                    maxDist = minDist
                    farthest = i
                }
            }
            centroids.append(embeddings[farthest])
        }

        var labels = [Int](repeating: 0, count: n)

        for _ in 0..<maxIter {
            // Assign
            var changed = false
            for i in 0..<n {
                var bestC = 0
                var bestSim = -Float.infinity
                for c in 0..<k {
                    let sim = cosineSim(embeddings[i], centroids[c])
                    if sim > bestSim { bestSim = sim; bestC = c }
                }
                if labels[i] != bestC { labels[i] = bestC; changed = true }
            }
            if !changed { break }

            // Update centroids
            for c in 0..<k {
                var sum = [Float](repeating: 0, count: dim)
                var count = 0
                for i in 0..<n {
                    if labels[i] == c {
                        for d in 0..<dim { sum[d] += embeddings[i][d] }
                        count += 1
                    }
                }
                if count > 0 {
                    let norm = l2Norm(sum)
                    centroids[c] = norm > 0 ? sum.map { $0 / norm } : sum
                }
            }
        }
        return labels
    }

    // MARK: - Silhouette Score

    static func silhouetteScore(_ embeddings: [[Float]], labels: [Int]) -> Double {
        let n = embeddings.count
        let k = Set(labels).count
        guard k >= 2, n > k else { return -1 }

        var total = 0.0
        for i in 0..<n {
            var intraSum = 0.0; var intraCount = 0
            var interSums = [Int: (sum: Double, count: Int)]()

            for j in 0..<n where j != i {
                let dist = Double(1.0 - cosineSim(embeddings[i], embeddings[j]))
                if labels[j] == labels[i] {
                    intraSum += dist; intraCount += 1
                } else {
                    let prev = interSums[labels[j]] ?? (0, 0)
                    interSums[labels[j]] = (prev.sum + dist, prev.count + 1)
                }
            }
            // Singleton clusters are undefined for silhouette; sklearn's
            // convention is to count them as 0 (so degenerate over-clustering
            // doesn't artificially win the score).
            if intraCount == 0 {
                continue
            }
            let a = intraSum / Double(intraCount)
            let b = interSums.values.map { $0.sum / Double($0.count) }.min() ?? 0
            let denom = max(a, b)
            // If both intra and inter distances are zero (e.g. all points
            // identical), the silhouette is undefined — treat as 0.
            total += denom > 0 ? (b - a) / denom : 0
        }
        return total / Double(n)
    }

    // MARK: - Automatic Speaker Count Selection

    /// Tries k=2..maxSpeakers, picks the k with the best silhouette score.
    static func clusterEmbeddings(
        _ embeddings: [[Float]], maxSpeakers: Int
    ) -> (labels: [Int], k: Int) {
        let n = embeddings.count
        guard n >= 2 else { return (Array(0..<n), n) }

        var bestLabels = [Int](repeating: 0, count: n)
        var bestScore = -Double.infinity
        var bestK = 2

        for k in 2...min(maxSpeakers, n - 1) {
            let labels = kMeans(embeddings, k: k)
            let score = silhouetteScore(embeddings, labels: labels)
            if score > bestScore {
                bestScore = score
                bestLabels = labels
                bestK = k
            }
        }

        return (bestLabels, bestK)
    }

    // MARK: - Cluster Confidence

    /// How much more similar an embedding is to its assigned cluster vs the next-best.
    static func clusterConfidence(_ embedding: [Float], allEmbeddings: [[Float]], labels: [Int]) -> Double {
        let k = Set(labels).count
        guard k >= 2 else { return 1.0 }

        var clusterSims = [Int: (sum: Double, count: Int)]()
        for (i, emb) in allEmbeddings.enumerated() {
            let sim = Double(cosineSim(embedding, emb))
            let prev = clusterSims[labels[i]] ?? (0, 0)
            clusterSims[labels[i]] = (prev.sum + sim, prev.count + 1)
        }
        let avgSims = clusterSims.values.map { $0.sum / Double($0.count) }.sorted()
        guard avgSims.count >= 2, let best = avgSims.last else { return 1.0 }
        return best - avgSims[avgSims.count - 2]
    }
}
