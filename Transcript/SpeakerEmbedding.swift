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
