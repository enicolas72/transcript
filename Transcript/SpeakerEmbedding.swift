import Foundation
import CoreML

/// CoreML-based speaker embedding computation using WeSpeaker FBank + ResNet34 models.
/// This is the only file that depends on CoreML for speaker detection.
enum SpeakerEmbedding {

    private static let sampleRate = 16000
    // WeSpeaker expects 10 seconds of audio at 16kHz = 160,000 samples
    private static let modelWindowSamples = 160_000
    // FBank output has 998 frames for 10s of audio; the Embedding model's weights
    // mask has 589 entries (segmentation temporal resolution for 10s window).
    // Both values are fixed by the CoreML model architecture — do not change
    // unless the upstream FBank/Embedding .mlmodelc files change.
    private static let maskFrames = 589
    // FBank model outputs 998 time frames for a 10-second input window
    private static let fbankFrames = 998
    // WeSpeaker ResNet34 produces 256-dimensional speaker embeddings
    static let embDim = 256

    struct Models {
        let fbankModel: MLModel
        let embeddingModel: MLModel
    }

    static func loadModels() throws -> Models {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TranscriptionError.diarizationFailed("Could not locate Application Support directory")
        }
        let modelsDir = appSupport.appendingPathComponent("FluidAudio/Models/speaker-diarization-coreml")

        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly  // FBank must run on CPU

        let fbankModel = try MLModel(contentsOf: modelsDir.appendingPathComponent("FBank.mlmodelc"), configuration: config)

        let embConfig = MLModelConfiguration()
        embConfig.computeUnits = .all
        let embeddingModel = try MLModel(contentsOf: modelsDir.appendingPathComponent("Embedding.mlmodelc"), configuration: embConfig)

        return Models(fbankModel: fbankModel, embeddingModel: embeddingModel)
    }

    /// Compute a single speaker embedding for an audio time range.
    static func computeEmbedding(
        models: Models,
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
        let norm = SpeakerClustering.l2Norm(embedding)
        if norm > 0 {
            for i in 0..<embDim { embedding[i] /= norm }
        }

        return embedding
    }
}

// MARK: - Audio-Driven Diarizer (used by non-English / Qwen3 pipeline)

/// Sliding-window speaker diarizer. Independent of any ASR output: it operates
/// directly on raw 16 kHz audio, computes one WeSpeaker embedding per fixed-size
/// window, clusters them, smooths short runs, and returns continuous speaker
/// turns. Used by the Qwen3 path where word-level timestamps are unavailable.
enum SpeakerDiarizer {

    static let sampleRate = 16_000
    /// Length of each embedding window in seconds.
    static let windowSeconds: Double = 2.0
    /// Hop between consecutive windows. Equal to windowSeconds → no overlap,
    /// keeping the per-file cost linear in audio duration.
    static let hopSeconds: Double = 2.0
    /// Run-length smoothing threshold (in windows). Two windows ≈ 4 seconds.
    static let minRunWindows = 2

    struct Turn: Equatable {
        let start: Double
        let end: Double
        let speaker: Int
    }

    /// Diarize an entire audio buffer into speaker turns.
    static func diarize(
        audioSamples: [Float],
        maxSpeakers: Int = 6,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [Turn] {
        let totalDuration = Double(audioSamples.count) / Double(sampleRate)
        guard totalDuration >= 1.0 else { return [] }

        let models = try SpeakerEmbedding.loadModels()

        // 1. Build window list
        var windows: [(start: Double, end: Double)] = []
        var t = 0.0
        while t < totalDuration {
            let end = min(t + windowSeconds, totalDuration)
            // Drop trailing windows shorter than 0.5 s — they don't carry
            // enough signal for a stable embedding.
            if end - t >= 0.5 {
                windows.append((start: t, end: end))
            }
            t += hopSeconds
        }
        guard !windows.isEmpty else { return [] }

        // 2. Embed each window
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(windows.count)
        for (i, w) in windows.enumerated() {
            let emb = try SpeakerEmbedding.computeEmbedding(
                models: models,
                audioSamples: audioSamples,
                startTime: w.start,
                endTime: w.end
            )
            embeddings.append(emb)
            onProgress?(Double(i + 1) / Double(windows.count))
        }

        // 3. Cluster — silhouette score picks k automatically.
        // For very small window counts, fall back to a single speaker.
        let labels: [Int]
        if windows.count >= 4 {
            (labels, _) = SpeakerClustering.clusterEmbeddings(embeddings, maxSpeakers: maxSpeakers)
        } else {
            labels = Array(repeating: 0, count: windows.count)
        }

        // 4. Smooth: absorb runs shorter than minRunWindows into neighbours.
        let smoothed = smoothLabels(labels, minRun: minRunWindows)

        // 5. Merge consecutive same-speaker windows into turns.
        var turns: [Turn] = []
        var i = 0
        while i < windows.count {
            var j = i
            while j < windows.count && smoothed[j] == smoothed[i] { j += 1 }
            turns.append(Turn(
                start: windows[i].start,
                end: windows[j - 1].end,
                speaker: smoothed[i]
            ))
            i = j
        }
        return turns
    }

    /// Run-length smoothing on integer labels. Mirrors `TranscriptMerger.smoothRuns`
    /// but operates on bare label arrays so it can be used outside the ASR-token
    /// world.
    static func smoothLabels(_ labels: [Int], minRun: Int) -> [Int] {
        var result = labels
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < result.count {
                var j = i
                while j < result.count && result[j] == result[i] { j += 1 }
                // See TranscriptMerger.smoothRuns for why boundary runs
                // are intentionally left alone.
                if j - i < minRun && i > 0 && j < result.count {
                    let absorb = result[i - 1]
                    for k in i..<j { result[k] = absorb }
                    changed = true
                }
                i = j
            }
        }
        return result
    }

    /// Convert a stable integer speaker id into a human-readable label
    /// ("Speaker A", "Speaker B", …) using first-appearance ordering.
    static func assignLabels(_ turns: [Turn]) -> [(start: Double, end: Double, speaker: String)] {
        var order: [Int: String] = [:]
        var next = 0
        var out: [(start: Double, end: Double, speaker: String)] = []
        for t in turns {
            if order[t.speaker] == nil {
                let letter: String
                if next < 26 {
                    letter = String(Character(UnicodeScalar(65 + next)!))
                } else {
                    letter = "\(next + 1)"
                }
                order[t.speaker] = "Speaker \(letter)"
                next += 1
            }
            out.append((start: t.start, end: t.end, speaker: order[t.speaker] ?? "Speaker A"))
        }
        return out
    }
}
