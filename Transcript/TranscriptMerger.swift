import Foundation
import CoreML
import FluidAudio
import Accelerate

/// Merges ASR tokens with speaker detection using per-sub-segment neural embeddings.
///
/// Strategy (mirrors the Python resemblyzer approach):
/// 1. Split ASR tokens at sentence punctuation into sub-segments
/// 2. Compute WeSpeaker neural embedding for each sub-segment
/// 3. Cluster embeddings to identify speakers
/// 4. Apply continuation carrying and run-length smoothing
enum TranscriptMerger {

    private static let sampleRate = 16000
    private static let modelWindowSamples = 160_000  // 10 seconds
    private static let maskFrames = 589              // segmentation frame count for 10s

    // MARK: - Public API

    static func merge(
        tokens: [TokenTiming],
        audioSamples: [Float]
    ) throws -> [LabeledSegment] {
        guard !tokens.isEmpty else { return [] }

        // Load FBank + Embedding models from FluidAudio cache
        let models = try loadModels()

        // Split tokens into sub-segments at sentence punctuation
        let subs = splitAtPunctuation(tokens)

        // Compute one neural embedding per sub-segment
        var subEmbeddings: [[Float]] = []
        for sub in subs {
            let emb = try computeEmbedding(
                models: models,
                audioSamples: audioSamples,
                startTime: sub.first!.startTime,
                endTime: sub.last!.endTime
            )
            subEmbeddings.append(emb)
        }

        // Cluster sub-segment embeddings into speakers
        let (labels, _) = clusterEmbeddings(subEmbeddings, maxSpeakers: 6)

        // Build labeled tokens with confidence
        var labeledTokens: [(token: TokenTiming, speaker: Int, confidence: Double)] = []
        for (i, sub) in subs.enumerated() {
            let conf = clusterConfidence(subEmbeddings[i], allEmbeddings: subEmbeddings, labels: labels)
            for t in sub {
                labeledTokens.append((token: t, speaker: labels[i], confidence: conf))
            }
        }

        // Post-process: continuation carrying + smoothing
        labeledTokens = carryAcrossContinuations(labeledTokens, subs: subs)
        labeledTokens = smoothRuns(labeledTokens, minRun: 5)

        // Reorder by first appearance and build output
        return buildOutput(labeledTokens)
    }

    // MARK: - Model Loading

    private struct EmbeddingModels {
        let fbankModel: MLModel
        let embeddingModel: MLModel
    }

    private static func loadModels() throws -> EmbeddingModels {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models/speaker-diarization-coreml")

        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly  // FBank must run on CPU

        let fbankModel = try MLModel(contentsOf: modelsDir.appendingPathComponent("FBank.mlmodelc"), configuration: config)

        let embConfig = MLModelConfiguration()
        embConfig.computeUnits = .all
        let embeddingModel = try MLModel(contentsOf: modelsDir.appendingPathComponent("Embedding.mlmodelc"), configuration: embConfig)

        return EmbeddingModels(fbankModel: fbankModel, embeddingModel: embeddingModel)
    }

    // MARK: - Per-Sub-Segment Embedding

    private static let fbankFrames = 998
    private static let embDim = 256

    private static func computeEmbedding(
        models: EmbeddingModels,
        audioSamples: [Float],
        startTime: TimeInterval,
        endTime: TimeInterval
    ) throws -> [Float] {
        let startSample = max(0, Int(startTime * Double(sampleRate)))
        let endSample = min(audioSamples.count, Int(endTime * Double(sampleRate)))

        // Pad audio to 10-second window
        var paddedAudio = [Float](repeating: 0, count: modelWindowSamples)
        let copyCount = min(endSample - startSample, modelWindowSamples)
        if copyCount > 0 && startSample < audioSamples.count {
            for i in 0..<copyCount {
                paddedAudio[i] = audioSamples[startSample + i]
            }
        }

        // Step 1: Run FBank model — audio [1,1,160000] → fbank_features [1,1,80,998]
        let audioArray = try MLMultiArray(shape: [1, 1, 160_000] as [NSNumber], dataType: .float32)
        for i in 0..<modelWindowSamples {
            audioArray[i] = NSNumber(value: paddedAudio[i])
        }
        let fbankInput = try MLDictionaryFeatureProvider(dictionary: ["audio": audioArray])
        let fbankOutput = try models.fbankModel.prediction(from: fbankInput)
        guard let fbankFeatures = fbankOutput.featureValue(for: "fbank_features")?.multiArrayValue else {
            return [Float](repeating: 0, count: embDim)
        }

        // Step 2: Create weights mask — active frames proportional to audio duration
        let duration = endTime - startTime
        let activeFrames = max(1, min(maskFrames, Int(duration * Double(maskFrames) / 10.0)))
        let weightsArray = try MLMultiArray(shape: [1, maskFrames as NSNumber], dataType: .float32)
        for i in 0..<maskFrames {
            weightsArray[i] = NSNumber(value: i < activeFrames ? Float(1.0) : Float(0.0))
        }

        // Step 3: Run Embedding model — fbank_features + weights → embedding
        let embInput = try MLDictionaryFeatureProvider(dictionary: [
            "fbank_features": fbankFeatures,
            "weights": weightsArray
        ])
        let embOutput = try models.embeddingModel.prediction(from: embInput)
        guard let embArray = embOutput.featureValue(for: "embedding")?.multiArrayValue else {
            return [Float](repeating: 0, count: embDim)
        }

        // Extract 256-dim embedding
        var embedding = [Float](repeating: 0, count: embDim)
        for i in 0..<min(embDim, embArray.count) {
            embedding[i] = embArray[i].floatValue
        }

        // L2 normalize
        let norm = l2Norm(embedding)
        if norm > 0 {
            for i in 0..<embDim { embedding[i] /= norm }
        }

        return embedding
    }

    // MARK: - Clustering (cosine similarity + k-means)

    private static func clusterEmbeddings(
        _ embeddings: [[Float]], maxSpeakers: Int
    ) -> (labels: [Int], k: Int) {
        let n = embeddings.count
        guard n >= 2 else { return (Array(0..<n), n) }

        // Try different k values, pick best silhouette
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

    private static func kMeans(_ embeddings: [[Float]], k: Int, maxIter: Int = 30) -> [Int] {
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

    private static func silhouetteScore(_ embeddings: [[Float]], labels: [Int]) -> Double {
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
            let a = intraCount > 0 ? intraSum / Double(intraCount) : 0
            let b = interSums.values.map { $0.sum / Double($0.count) }.min() ?? 0
            total += (b - a) / max(a, b)
        }
        return total / Double(n)
    }

    private static func clusterConfidence(_ embedding: [Float], allEmbeddings: [[Float]], labels: [Int]) -> Double {
        let k = Set(labels).count
        guard k >= 2 else { return 1.0 }

        // Compute mean similarity to each cluster
        var clusterSims = [Int: (sum: Double, count: Int)]()
        for (i, emb) in allEmbeddings.enumerated() {
            let sim = Double(cosineSim(embedding, emb))
            let prev = clusterSims[labels[i]] ?? (0, 0)
            clusterSims[labels[i]] = (prev.sum + sim, prev.count + 1)
        }
        let avgSims = clusterSims.values.map { $0.sum / Double($0.count) }.sorted()
        return avgSims.count >= 2 ? avgSims.last! - avgSims[avgSims.count - 2] : 1.0
    }

    private static func cosineSim(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    private static func l2Norm(_ v: [Float]) -> Float {
        var sum: Float = 0
        vDSP_dotpr(v, 1, v, 1, &sum, vDSP_Length(v.count))
        return sqrt(sum)
    }

    // MARK: - Punctuation Splitting

    private static func splitAtPunctuation(_ tokens: [TokenTiming], minWords: Int = 3) -> [[TokenTiming]] {
        var subs: [[TokenTiming]] = []
        var current: [TokenTiming] = []

        for t in tokens {
            current.append(t)
            let word = t.token.trimmingCharacters(in: .whitespaces)
            if word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!") {
                if current.count >= minWords {
                    subs.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty {
            if subs.isEmpty || current.count >= minWords {
                subs.append(current)
            } else {
                subs[subs.count - 1].append(contentsOf: current)
            }
        }
        return subs.isEmpty ? [tokens] : subs
    }

    // MARK: - Continuation Carrying

    private static func carryAcrossContinuations(
        _ labeled: [(token: TokenTiming, speaker: Int, confidence: Double)],
        subs: [[TokenTiming]]
    ) -> [(token: TokenTiming, speaker: Int, confidence: Double)] {
        var result = labeled
        let confs = result.map(\.confidence)
        let medianConf = confs.sorted()[confs.count / 2]

        var tokenIdx = 0
        var prevSpeaker: Int? = nil
        var prevEndedWithPunct = true

        for sub in subs {
            let subLen = sub.count
            guard tokenIdx < result.count else { break }

            if !prevEndedWithPunct, let prev = prevSpeaker {
                let subConf = result[tokenIdx].confidence
                if subConf < medianConf {
                    for i in tokenIdx..<min(tokenIdx + subLen, result.count) {
                        result[i].speaker = prev
                    }
                }
            }

            prevSpeaker = result[tokenIdx].speaker
            let lastWord = sub.last?.token.trimmingCharacters(in: .whitespaces) ?? ""
            prevEndedWithPunct = lastWord.hasSuffix(".") || lastWord.hasSuffix("?") || lastWord.hasSuffix("!")
            tokenIdx += subLen
        }
        return result
    }

    // MARK: - Smoothing

    private static func smoothRuns(
        _ labeled: [(token: TokenTiming, speaker: Int, confidence: Double)],
        minRun: Int
    ) -> [(token: TokenTiming, speaker: Int, confidence: Double)] {
        var result = labeled
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < result.count {
                var j = i
                while j < result.count && result[j].speaker == result[i].speaker { j += 1 }
                if j - i < minRun && (i > 0 || j < result.count) {
                    let absorb = i > 0 ? result[i - 1].speaker : result[j].speaker
                    for k in i..<j { result[k].speaker = absorb }
                    changed = true
                }
                i = j
            }
        }
        return result
    }

    // MARK: - Output Building

    private static func buildOutput(
        _ labeled: [(token: TokenTiming, speaker: Int, confidence: Double)]
    ) -> [LabeledSegment] {
        var speakerOrder: [Int: String] = [:]
        var nextLabel = 0
        for lt in labeled {
            if speakerOrder[lt.speaker] == nil {
                let letter = nextLabel < 26 ? String(Character(UnicodeScalar(65 + nextLabel)!)) : "\(nextLabel + 1)"
                speakerOrder[lt.speaker] = "Speaker \(letter)"
                nextLabel += 1
            }
        }

        var result: [LabeledSegment] = []
        var currentSpeaker = ""
        var currentText = ""
        var segStart = 0.0
        var segEnd = 0.0

        for lt in labeled {
            let label = speakerOrder[lt.speaker] ?? "Speaker A"
            if label != currentSpeaker {
                if !currentText.isEmpty {
                    result.append(LabeledSegment(start: segStart, end: segEnd,
                        text: currentText.trimmingCharacters(in: .whitespaces), speaker: currentSpeaker))
                }
                currentSpeaker = label
                currentText = lt.token.token
                segStart = lt.token.startTime
            } else {
                currentText += lt.token.token
            }
            segEnd = lt.token.endTime
        }
        if !currentText.isEmpty {
            result.append(LabeledSegment(start: segStart, end: segEnd,
                text: currentText.trimmingCharacters(in: .whitespaces), speaker: currentSpeaker))
        }
        return result
    }
}
