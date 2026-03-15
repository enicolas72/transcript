import Foundation
import AVFoundation
import FluidAudio

final class TranscriptionService: @unchecked Sendable {
    private var asrManager: AsrManager?

    func transcribe(
        fileURL: URL,
        outputDir: URL?,
        txtEnabled: Bool,
        srtEnabled: Bool,
        speakerDetection: Bool,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> TranscriptionResult {

        // 1. Prepare models (downloads on first use)
        try await ensureModels(onProgress: onProgress)

        // 2. Probe duration
        let duration = await probeDuration(fileURL: fileURL)
        if let dur = duration {
            let m = Int(dur) / 60; let s = Int(dur) % 60
            onProgress(ProgressUpdate(kind: .log("File duration: \(m)m\(s)s")))
        }

        // 3. Extract audio to temp WAV (works for both audio and video files)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        onProgress(ProgressUpdate(kind: .status("Extracting audio...")))
        let wavFile = tmpDir.appendingPathComponent("audio.wav")
        let samples = try await extractAudioSamples(from: fileURL)
        let wavData = try AudioWAV.data(from: samples, sampleRate: 16000)
        try wavData.write(to: wavFile)
        onProgress(ProgressUpdate(kind: .log("Audio extracted: \(samples.count / 16000)s")))

        // 4. Transcribe with Parakeet ASR
        onProgress(ProgressUpdate(kind: .status("Transcribing...")))
        onProgress(ProgressUpdate(kind: .log("Running speech recognition...")))

        guard let asr = asrManager else {
            throw TranscriptionError.noOutput
        }
        let asrResult = try await asr.transcribe(wavFile, source: .system)

        guard let tokens = asrResult.tokenTimings, !tokens.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        onProgress(ProgressUpdate(kind: .log("Transcription complete: \(tokens.count) words")))
        onProgress(ProgressUpdate(kind: .progress(0.7)))

        // 5. Generate outputs
        let destDir = outputDir ?? fileURL.deletingLastPathComponent()
        let inputBase = fileURL.deletingPathExtension().lastPathComponent

        var txtPath: String? = nil
        var srtPath: String? = nil

        if txtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).txt").path
            let content: String

            if speakerDetection {
                do {
                    onProgress(ProgressUpdate(kind: .status("Analyzing speakers...")))
                    onProgress(ProgressUpdate(kind: .log("\nRunning speaker detection...")))

                    let labeled = try TranscriptMerger.merge(
                        tokens: tokens,
                        audioSamples: samples)

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

    // MARK: - Model Preparation

    private func ensureModels(
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        if asrManager == nil {
            onProgress(ProgressUpdate(kind: .status("Downloading speech recognition model...")))
            onProgress(ProgressUpdate(kind: .log("Preparing ASR model (first run downloads ~600 MB)...")))

            let models = try await AsrModels.downloadAndLoad(
                version: .v3
            ) { progress in
                Task { @MainActor in
                    onProgress(ProgressUpdate(kind: .progress(progress.fractionCompleted * 0.3)))
                }
            }
            let asr = AsrManager()
            try await asr.initialize(models: models)
            asrManager = asr

            onProgress(ProgressUpdate(kind: .log("ASR model ready.")))
        }

        // Speaker embedding model is downloaded with the diarization models
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let embeddingModelPath = appSupport
            .appendingPathComponent("FluidAudio/Models/speaker-diarization-coreml/Embedding.mlmodelc")
        if !FileManager.default.fileExists(atPath: embeddingModelPath.path) {
            onProgress(ProgressUpdate(kind: .status("Downloading speaker detection model...")))
            onProgress(ProgressUpdate(kind: .log("Preparing speaker embedding model (~100 MB)...")))

            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()

            onProgress(ProgressUpdate(kind: .log("Speaker embedding model ready.")))
        }

        onProgress(ProgressUpdate(kind: .progress(0.3)))
    }

    // MARK: - Audio Extraction

    private func extractAudioSamples(from url: URL) async throws -> [Float] {
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
