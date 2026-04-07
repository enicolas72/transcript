import Foundation
import AVFoundation
import FluidAudio

/// Thread-safety: cached managers are written once during ensureModels() and
/// read thereafter. The lock ensures safe publication across actor boundaries.
final class TranscriptionService: @unchecked Sendable {
    private let lock = NSLock()
    private var _asrManager: AsrManager?
    private var asrManager: AsrManager? {
        get { lock.withLock { _asrManager } }
        set { lock.withLock { _asrManager = newValue } }
    }
    /// Type-erased Qwen3AsrManager (only available on macOS 15+).
    private var _qwen3Manager: Any?
    private var qwen3Manager: Any? {
        get { lock.withLock { _qwen3Manager } }
        set { lock.withLock { _qwen3Manager = newValue } }
    }

    func transcribe(
        fileURL: URL,
        outputDir: URL?,
        txtEnabled: Bool,
        srtEnabled: Bool,
        speakerDetection: Bool,
        language: TranscriptLanguage = .english,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> TranscriptionResult {

        // 1. Prepare models for the chosen language
        try await ensureModels(language: language, speakerDetection: speakerDetection, onProgress: onProgress)

        // 2. Probe duration
        let duration = await probeDuration(fileURL: fileURL)
        if let dur = duration {
            let m = Int(dur) / 60; let s = Int(dur) % 60
            onProgress(ProgressUpdate(kind: .log("File duration: \(m)m\(s)s")))
        }

        // 3. Extract audio (16 kHz mono Float32)
        onProgress(ProgressUpdate(kind: .status("Extracting audio...")))
        let samples = try await Self.extractAudioSamples(from: fileURL)
        onProgress(ProgressUpdate(kind: .log("Audio extracted: \(samples.count / 16000)s")))

        let destDir = outputDir ?? fileURL.deletingLastPathComponent()
        let inputBase = fileURL.deletingPathExtension().lastPathComponent

        // 4. Branch on language: English uses Parakeet (with word timestamps),
        //    everything else uses Qwen3 with audio-driven diarization.
        if language.usesParakeet {
            return try await runParakeetPipeline(
                fileURL: fileURL, samples: samples,
                destDir: destDir, inputBase: inputBase,
                txtEnabled: txtEnabled, srtEnabled: srtEnabled,
                speakerDetection: speakerDetection,
                onProgress: onProgress)
        } else {
            if #available(macOS 15, *) {
                return try await runQwen3Pipeline(
                    samples: samples,
                    destDir: destDir, inputBase: inputBase,
                    txtEnabled: txtEnabled, srtEnabled: srtEnabled,
                    speakerDetection: speakerDetection,
                    language: language,
                    onProgress: onProgress)
            } else {
                throw TranscriptionError.unsupportedOSForLanguage(language.displayName)
            }
        }
    }

    // MARK: - Parakeet pipeline (English, word-timestamp aligned)

    private func runParakeetPipeline(
        fileURL: URL,
        samples: [Float],
        destDir: URL,
        inputBase: String,
        txtEnabled: Bool,
        srtEnabled: Bool,
        speakerDetection: Bool,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> TranscriptionResult {

        // Write a temp WAV for AsrManager
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let wavFile = tmpDir.appendingPathComponent("audio.wav")
        let wavData = try AudioWAV.data(from: samples, sampleRate: 16000)
        try wavData.write(to: wavFile)

        onProgress(ProgressUpdate(kind: .status("Transcribing...")))
        onProgress(ProgressUpdate(kind: .log("Running speech recognition (Parakeet, English)...")))

        guard let asr = asrManager else {
            throw TranscriptionError.noOutput
        }
        let asrResult = try await asr.transcribe(wavFile, source: .system)
        guard let tokens = asrResult.tokenTimings, !tokens.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        onProgress(ProgressUpdate(kind: .log("Transcription complete: \(tokens.count) words")))
        onProgress(ProgressUpdate(kind: .progress(0.7)))

        var txtPath: String? = nil
        var srtPath: String? = nil

        if txtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).txt").path
            let content: String
            if speakerDetection {
                do {
                    onProgress(ProgressUpdate(kind: .status("Analyzing speakers...")))
                    onProgress(ProgressUpdate(kind: .log("\nRunning speaker detection...")))
                    let labeled = try TranscriptMerger.merge(tokens: tokens, audioSamples: samples)
                    let speakerCount = Set(labeled.map(\.speaker)).count
                    onProgress(ProgressUpdate(kind: .log("Detected \(speakerCount) speaker(s)")))
                    content = OutputGenerator.generateTXTWithSpeakers(labeled)
                } catch {
                    onProgress(ProgressUpdate(kind: .log(
                        "Speaker detection failed: \(error.localizedDescription). Continuing without speaker labels.")))
                    content = OutputGenerator.generateTXTFromTokens(tokens)
                }
            } else {
                content = OutputGenerator.generateTXTFromTokens(tokens)
            }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            txtPath = path
        }

        if srtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).srt").path
            let content = OutputGenerator.generateSRTFromTokens(tokens)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            srtPath = path
        }

        onProgress(ProgressUpdate(kind: .progress(1.0)))
        return TranscriptionResult(txtPath: txtPath, srtPath: srtPath)
    }

    // MARK: - Qwen3 pipeline (multilingual, diarize-first then per-turn ASR)

    @available(macOS 15, *)
    private func runQwen3Pipeline(
        samples: [Float],
        destDir: URL,
        inputBase: String,
        txtEnabled: Bool,
        srtEnabled: Bool,
        speakerDetection: Bool,
        language: TranscriptLanguage,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> TranscriptionResult {

        guard let qwen3 = qwen3Manager as? Qwen3AsrManager else {
            throw TranscriptionError.modelDownloadFailed("Qwen3 model not loaded")
        }

        // The language hint for Qwen3 — pass nil for automatic detection.
        let langHint: Qwen3AsrConfig.Language?
        if language == .auto {
            langHint = nil
        } else {
            langHint = Qwen3AsrConfig.Language(rawValue: language.rawValue)
        }

        // Build the speaker turns we'll feed Qwen3 with. If diarization is
        // disabled, we treat the whole file as a single anonymous turn.
        var labeledTurns: [(start: Double, end: Double, speaker: String)]
        if speakerDetection {
            onProgress(ProgressUpdate(kind: .status("Analyzing speakers...")))
            onProgress(ProgressUpdate(kind: .log(
                "Running speaker diarization (sliding-window WeSpeaker)...")))

            let turns = try SpeakerDiarizer.diarize(
                audioSamples: samples,
                maxSpeakers: 6,
                onProgress: { frac in
                    Task { @MainActor in
                        onProgress(ProgressUpdate(kind: .progress(0.3 + frac * 0.3)))
                    }
                }
            )
            let speakerCount = Set(turns.map(\.speaker)).count
            onProgress(ProgressUpdate(kind: .log(
                "Detected \(speakerCount) speaker(s) across \(turns.count) turns")))
            labeledTurns = SpeakerDiarizer.assignLabels(turns)
        } else {
            let totalDuration = Double(samples.count) / 16000.0
            labeledTurns = [(start: 0.0, end: totalDuration, speaker: "")]
        }

        // Transcribe each turn separately. Per-turn ASR is what gives us
        // speaker-correct text without any forced text/time alignment.
        onProgress(ProgressUpdate(kind: .status("Transcribing...")))
        onProgress(ProgressUpdate(kind: .log(
            "Running speech recognition (Qwen3-ASR, \(language.displayName))...")))

        var segments: [LabeledSegment] = []
        for (i, turn) in labeledTurns.enumerated() {
            let startSample = max(0, Int(turn.start * 16000))
            let endSample = min(samples.count, Int(turn.end * 16000))
            guard endSample > startSample else { continue }
            // Skip turns shorter than 0.3 s — too short for stable ASR.
            if Double(endSample - startSample) / 16000.0 < 0.3 { continue }

            let slice = Array(samples[startSample..<endSample])
            do {
                let text = try await qwen3.transcribe(
                    audioSamples: slice,
                    language: langHint
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append(LabeledSegment(
                        start: turn.start, end: turn.end,
                        text: trimmed, speaker: turn.speaker))
                }
            } catch {
                onProgress(ProgressUpdate(kind: .log(
                    "Turn \(i + 1) failed: \(error.localizedDescription)")))
            }

            let frac = 0.6 + (0.35 * Double(i + 1) / Double(labeledTurns.count))
            onProgress(ProgressUpdate(kind: .progress(frac)))
        }

        guard !segments.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }
        onProgress(ProgressUpdate(kind: .log("Transcription complete: \(segments.count) segments")))

        var txtPath: String? = nil
        var srtPath: String? = nil

        if txtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).txt").path
            let content: String
            if speakerDetection {
                content = OutputGenerator.generateTXTWithSpeakers(segments)
            } else {
                content = OutputGenerator.generateTXTFromSegments(segments)
            }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            txtPath = path
        }

        if srtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).srt").path
            let content = OutputGenerator.generateSRTFromSegments(segments)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            srtPath = path
        }

        onProgress(ProgressUpdate(kind: .progress(1.0)))
        return TranscriptionResult(txtPath: txtPath, srtPath: srtPath)
    }

    // MARK: - Model Preparation

    private static let maxRetries = 3

    private func ensureModels(
        language: TranscriptLanguage,
        speakerDetection: Bool,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        if language.usesParakeet {
            try await ensureParakeet(onProgress: onProgress)
        } else {
            if #available(macOS 15, *) {
                try await ensureQwen3(onProgress: onProgress)
            } else {
                throw TranscriptionError.unsupportedOSForLanguage(language.displayName)
            }
        }

        // WeSpeaker is needed whenever speaker detection is on (for both
        // pipelines: Parakeet uses it for sub-segment embeddings, Qwen3 uses
        // it for sliding-window diarization).
        if speakerDetection {
            try await ensureSpeakerEmbedding(onProgress: onProgress)
        }

        onProgress(ProgressUpdate(kind: .progress(0.3)))
    }

    private func ensureParakeet(
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        if asrManager != nil { return }
        onProgress(ProgressUpdate(kind: .status("Downloading speech recognition model...")))
        onProgress(ProgressUpdate(kind: .log("Preparing ASR model (first run downloads ~600 MB)...")))

        let models = try await withRetry(maxAttempts: Self.maxRetries, label: "ASR model download", onProgress: onProgress) {
            try await AsrModels.downloadAndLoad(
                version: .v3
            ) { progress in
                Task { @MainActor in
                    onProgress(ProgressUpdate(kind: .progress(progress.fractionCompleted * 0.3)))
                }
            }
        }
        let asr = AsrManager()
        try await asr.loadModels(models)
        asrManager = asr
        onProgress(ProgressUpdate(kind: .log("ASR model ready.")))
    }

    @available(macOS 15, *)
    private func ensureQwen3(
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        if qwen3Manager is Qwen3AsrManager { return }
        onProgress(ProgressUpdate(kind: .status("Downloading multilingual ASR model...")))
        onProgress(ProgressUpdate(kind: .log("Preparing Qwen3-ASR model (first run downloads ~1.75 GB)...")))

        let modelDir = try await withRetry(maxAttempts: Self.maxRetries, label: "Qwen3-ASR model download", onProgress: onProgress) {
            try await Qwen3AsrModels.download(variant: .f32) { progress in
                Task { @MainActor in
                    onProgress(ProgressUpdate(kind: .progress(progress.fractionCompleted * 0.3)))
                }
            }
        }
        let manager = Qwen3AsrManager()
        try await manager.loadModels(from: modelDir)
        qwen3Manager = manager
        onProgress(ProgressUpdate(kind: .log("Qwen3-ASR model ready.")))
    }

    private func ensureSpeakerEmbedding(
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        // Speaker embedding model is downloaded with the diarization models
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TranscriptionError.modelDownloadFailed("Could not locate Application Support directory")
        }
        let embeddingModelPath = appSupport
            .appendingPathComponent("FluidAudio/Models/speaker-diarization-coreml/Embedding.mlmodelc")
        if FileManager.default.fileExists(atPath: embeddingModelPath.path) { return }

        onProgress(ProgressUpdate(kind: .status("Downloading speaker detection model...")))
        onProgress(ProgressUpdate(kind: .log("Preparing speaker embedding model (~100 MB)...")))

        try await withRetry(maxAttempts: Self.maxRetries, label: "Speaker model download", onProgress: onProgress) {
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
        }
        onProgress(ProgressUpdate(kind: .log("Speaker embedding model ready.")))
    }

    private func withRetry<T>(
        maxAttempts: Int,
        label: String,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delay = attempt * 2  // 2s, 4s backoff
                    onProgress(ProgressUpdate(kind: .log(
                        "\(label) failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription). Retrying in \(delay)s...")))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw TranscriptionError.modelDownloadFailed(lastError?.localizedDescription ?? "Unknown error after \(maxAttempts) attempts")
    }

    // MARK: - Audio Extraction

    /// Extract 16kHz mono Float32 samples from any audio/video file.
    static func extractAudioSamples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionError.noOutput
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        reader.startReading()

        var samples = [Float]()
        while let buffer = trackOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &ptr)
            if let ptr = ptr, length > 0 {
                let count = length / MemoryLayout<Float>.size
                ptr.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
                    samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
                }
            }
        }

        guard reader.status == .completed, !samples.isEmpty else {
            throw TranscriptionError.noOutput
        }
        return samples
    }

    // MARK: - Duration Probe

    private func probeDuration(fileURL: URL) async -> Double? {
        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : nil
        } catch {
            return nil
        }
    }
}
