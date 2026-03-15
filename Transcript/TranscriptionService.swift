import Foundation

final class TranscriptionService: Sendable {
    private let whisperPath = "/opt/homebrew/bin/whisper"
    private let pythonPath = "/opt/homebrew/opt/python@3.11/bin/python3.11"

    private let modelMinSizes: [String: Int] = [
        "tiny": 70_000_000,
        "base": 130_000_000,
        "small": 450_000_000,
        "medium": 1_400_000_000,
        "large": 2_800_000_000,
    ]

    private let filteredPrefixes = [
        "Detecting language",
        "FP16 is not supported",
    ]

    func transcribe(
        fileURL: URL,
        model: String,
        outputDir: URL?,
        txtEnabled: Bool,
        srtEnabled: Bool,
        speakerDetection: Bool,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> TranscriptionResult {
        try await ensureModel(model, onProgress: onProgress)

        let duration = await probeDuration(filePath: fileURL.path)
        if let dur = duration {
            let m = Int(dur) / 60
            let s = Int(dur) % 60
            onProgress(ProgressUpdate(kind: .log("File duration: \(m)m\(s)s")))
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try await runWhisper(
            inputFile: fileURL.path,
            model: model,
            outputDir: tmpDir.path,
            duration: duration,
            wordTimestamps: speakerDetection,
            onProgress: onProgress
        )

        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let jsonFile = tmpDir.appendingPathComponent("\(baseName).json")

        guard FileManager.default.fileExists(atPath: jsonFile.path) else {
            throw TranscriptionError.noOutput
        }

        let data = try Data(contentsOf: jsonFile)
        let whisperOutput = try JSONDecoder().decode(WhisperOutput.self, from: data)

        guard !whisperOutput.segments.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        let destDir = outputDir ?? fileURL.deletingLastPathComponent()
        let inputBase = fileURL.deletingPathExtension().lastPathComponent

        var txtPath: String? = nil
        var srtPath: String? = nil

        if txtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).txt").path
            let content: String
            if speakerDetection {
                do {
                    content = try await runSpeakerDiarization(
                        fileURL: fileURL,
                        whisperJSON: jsonFile,
                        tmpDir: tmpDir,
                        onProgress: onProgress
                    )
                } catch {
                    onProgress(ProgressUpdate(kind: .log(
                        "Speaker detection failed: \(error.localizedDescription). Continuing without speaker labels.")))
                    content = OutputGenerator.generateTXT(whisperOutput.segments)
                }
            } else {
                content = OutputGenerator.generateTXT(whisperOutput.segments)
            }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            txtPath = path
        }

        if srtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).srt").path
            let content = OutputGenerator.generateSRT(whisperOutput.segments)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            srtPath = path
        }

        return TranscriptionResult(txtPath: txtPath, srtPath: srtPath)
    }

    // MARK: - Speaker Diarization

    private func runSpeakerDiarization(
        fileURL: URL,
        whisperJSON: URL,
        tmpDir: URL,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> String {
        onProgress(ProgressUpdate(kind: .status("Extracting audio...")))

        // Extract audio to 16kHz mono wav for speaker analysis
        let wavFile = tmpDir.appendingPathComponent("audio.wav")
        try await extractWav(from: fileURL, to: wavFile)

        // Find the diarize.py script in the app bundle
        guard let scriptPath = Bundle.main.path(forResource: "diarize", ofType: "py") else {
            throw TranscriptionError.diarizationFailed("diarize.py not found in app bundle")
        }

        onProgress(ProgressUpdate(kind: .status("Analyzing speakers...")))
        onProgress(ProgressUpdate(kind: .log("Running speaker diarization...")))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, wavFile.path, whisperJSON.path]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                    let lines = errStr.components(separatedBy: "\n").filter { !$0.isEmpty }
                    for line in lines {
                        Task { @MainActor in
                            onProgress(ProgressUpdate(kind: .log(line)))
                        }
                    }
                }

                if proc.terminationStatus == 0,
                   let output = String(data: outData, encoding: .utf8),
                   !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(returning: output)
                } else {
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: TranscriptionError.diarizationFailed(errMsg))
                }
            }

            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private func extractWav(from input: URL, to output: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-y", "-i", input.path,
            "-ac", "1", "-ar", "16000",
            "-v", "quiet",
            output.path
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TranscriptionError.diarizationFailed(
                        "Failed to extract audio (ffmpeg exit \(proc.terminationStatus))"))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Duration Probe

    private func probeDuration(filePath: String) async -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            filePath
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let format = json["format"] as? [String: Any],
               let durStr = format["duration"] as? String,
               let dur = Double(durStr) {
                return dur
            }
        } catch {}
        return nil
    }

    // MARK: - Model Download

    private func ensureModel(
        _ model: String,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper")
        let modelFile = cacheDir.appendingPathComponent("\(model).pt")

        if FileManager.default.fileExists(atPath: modelFile.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: modelFile.path)
            let size = attrs?[.size] as? Int ?? 0
            let minSize = modelMinSizes[model] ?? 0

            if size >= minSize { return }

            onProgress(ProgressUpdate(kind: .log("Removing corrupt model file...")))
            try? FileManager.default.removeItem(at: modelFile)
        }

        onProgress(ProgressUpdate(kind: .status("Downloading model '\(model)'...")))
        onProgress(ProgressUpdate(kind: .log("Downloading model '\(model)'... (this may take a few minutes)")))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "import whisper; whisper.load_model('\(model)', download_root=None)"]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TranscriptionError.modelDownloadFailed(model: model))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }

        if FileManager.default.fileExists(atPath: modelFile.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: modelFile.path)
            let size = attrs?[.size] as? Int ?? 0
            if size >= (modelMinSizes[model] ?? 0) {
                onProgress(ProgressUpdate(kind: .log("Model '\(model)' downloaded successfully.")))
                return
            }
        }

        throw TranscriptionError.modelDownloadFailed(model: model)
    }

    // MARK: - Whisper Process

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[(\d+):(\d+\.\d+)\s*-->\s*(\d+):(\d+\.\d+)\]"#
    )

    private func parseEndTime(from line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = Self.timestampRegex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 5,
              let endMinRange = Range(match.range(at: 3), in: line),
              let endSecRange = Range(match.range(at: 4), in: line),
              let endMin = Double(line[endMinRange]),
              let endSec = Double(line[endSecRange]) else { return nil }
        return endMin * 60.0 + endSec
    }

    private func runWhisper(
        inputFile: String,
        model: String,
        outputDir: String,
        duration: Double?,
        wordTimestamps: Bool,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)

        var args = [
            inputFile,
            "--model", model,
            "--output_format", "json",
            "--output_dir", outputDir,
            "--verbose", "True",
            "--fp16", "False"
        ]
        if wordTimestamps {
            args += ["--word_timestamps", "True"]
        }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        let throttle = ThrottledOutput(interval: 0.3) { lines, endTime in
            if !lines.isEmpty {
                onProgress(ProgressUpdate(kind: .log(lines.joined(separator: "\n"))))
            }
            if let endTime = endTime, let duration = duration, duration > 0 {
                let fraction = min(endTime / duration, 1.0)
                onProgress(ProgressUpdate(kind: .progress(fraction)))
                let pct = Int(fraction * 100)
                let etMin = Int(endTime) / 60
                let etSec = Int(endTime) % 60
                onProgress(ProgressUpdate(kind: .status(
                    "Transcribing... \(pct)% (\(etMin):\(String(format: "%02d", etSec)))"
                )))
            }
        }

        let filteredPrefixes = self.filteredPrefixes

        let lineBuffer = LineBuffer { line in
            for prefix in filteredPrefixes {
                if line.hasPrefix(prefix) { return }
            }
            throttle.addLine(line)
        }

        let parseEndTime = self.parseEndTime
        let timestampLineBuffer = LineBuffer { line in
            if let endTime = parseEndTime(line) {
                throttle.updateEndTime(endTime)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            lineBuffer.append(str)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            timestampLineBuffer.append(str)
            lineBuffer.append(str)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                lineBuffer.flush()
                timestampLineBuffer.flush()
                throttle.forceFlush()

                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TranscriptionError.whisperFailed(
                        exitCode: proc.terminationStatus
                    ))
                }
            }

            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}
