import Foundation

struct TranscriptionResult {
    let txtPath: String?
    let srtPath: String?
}

struct WhisperSegment: Decodable {
    let start: Double
    let end: Double
    let text: String
}

struct WhisperOutput: Decodable {
    let segments: [WhisperSegment]
}

/// Callback for progress updates from the transcription service.
struct ProgressUpdate: Sendable {
    enum Kind: Sendable {
        case log(String)
        case progress(Double)
        case status(String)
    }
    let kind: Kind
}

final class TranscriptionService: Sendable {
    private let whisperPath = "/opt/homebrew/bin/whisper"

    // Expected minimum sizes (bytes) for each model to detect corrupt/partial downloads
    private let modelMinSizes: [String: Int] = [
        "tiny": 70_000_000,
        "base": 130_000_000,
        "small": 450_000_000,
        "medium": 1_400_000_000,
        "large": 2_800_000_000,
    ]

    // Whisper noise lines to filter from the log
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
        // Ensure model is downloaded before transcription
        try await ensureModel(model, onProgress: onProgress)

        // Probe file duration for progress bar
        let duration = await probeDuration(filePath: fileURL.path)
        if let dur = duration {
            let m = Int(dur) / 60
            let s = Int(dur) % 60
            onProgress(ProgressUpdate(kind: .log("File duration: \(m)m\(s)s")))
        }

        // Create temp directory for whisper output
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Run whisper
        try await runWhisper(
            inputFile: fileURL.path,
            model: model,
            outputDir: tmpDir.path,
            duration: duration,
            onProgress: onProgress
        )

        // Find the JSON output file
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let jsonFile = tmpDir.appendingPathComponent("\(baseName).json")

        guard FileManager.default.fileExists(atPath: jsonFile.path) else {
            throw TranscriptionError.noOutput
        }

        // Parse JSON
        let data = try Data(contentsOf: jsonFile)
        let whisperOutput = try JSONDecoder().decode(WhisperOutput.self, from: data)

        guard !whisperOutput.segments.isEmpty else {
            throw TranscriptionError.emptyTranscription
        }

        // Determine output directory
        let destDir = outputDir ?? fileURL.deletingLastPathComponent()
        let inputBase = fileURL.deletingPathExtension().lastPathComponent

        var txtPath: String? = nil
        var srtPath: String? = nil

        // Generate .txt
        if txtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).txt").path
            let content: String
            if speakerDetection {
                let labeled = assignSpeakers(whisperOutput.segments)
                content = generateTXTWithSpeakers(labeled)
            } else {
                content = generateTXT(whisperOutput.segments)
            }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            txtPath = path
        }

        // Generate .srt
        if srtEnabled {
            let path = destDir.appendingPathComponent("\(inputBase).srt").path
            let content = generateSRT(whisperOutput.segments)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            srtPath = path
        }

        return TranscriptionResult(txtPath: txtPath, srtPath: srtPath)
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

            if size >= minSize {
                return
            }

            onProgress(ProgressUpdate(kind: .log("Removing corrupt model file...")))
            try? FileManager.default.removeItem(at: modelFile)
        }

        onProgress(ProgressUpdate(kind: .status("Downloading model '\(model)'...")))
        onProgress(ProgressUpdate(kind: .log("Downloading model '\(model)'... (this may take a few minutes)")))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/opt/python@3.11/bin/python3.11")
        process.arguments = [
            "-c",
            "import whisper; whisper.load_model('\(model)', download_root=None)"
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
                    continuation.resume(throwing: TranscriptionError.modelDownloadFailed(model: model))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        if FileManager.default.fileExists(atPath: modelFile.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: modelFile.path)
            let size = attrs?[.size] as? Int ?? 0
            let minSize = modelMinSizes[model] ?? 0
            if size >= minSize {
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
        guard let match = Self.timestampRegex.firstMatch(in: line, range: range) else { return nil }
        guard match.numberOfRanges >= 5,
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
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            inputFile,
            "--model", model,
            "--output_format", "json",
            "--output_dir", outputDir,
            "--verbose", "True",
            "--fp16", "False"
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        let throttle = ThrottledOutput(interval: 0.3, onFlush: { lines, endTime in
            if !lines.isEmpty {
                let joined = lines.joined(separator: "\n")
                onProgress(ProgressUpdate(kind: .log(joined)))
            }
            if let endTime = endTime, let duration = duration, duration > 0 {
                let fraction = min(endTime / duration, 1.0)
                onProgress(ProgressUpdate(kind: .progress(fraction)))
                let pct = Int(fraction * 100)
                let etMin = Int(endTime) / 60
                let etSec = Int(endTime) % 60
                onProgress(ProgressUpdate(kind: .status("Transcribing... \(pct)% (\(etMin):\(String(format: "%02d", etSec)))")))
            }
        })

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
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                lineBuffer.append(str)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                timestampLineBuffer.append(str)
                lineBuffer.append(str)
            }
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

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Speaker Detection

    struct LabeledSegment {
        let start: Double
        let end: Double
        let text: String
        let speaker: String
    }

    /// Assign speakers based on pause gaps between segments.
    ///
    /// Heuristic: compute the median gap across all segments, then only toggle
    /// speaker when a gap is significantly larger than the median (2x the median
    /// or at least 2 seconds, whichever is greater). This avoids false positives
    /// from natural within-speaker pauses.
    private func assignSpeakers(_ segments: [WhisperSegment]) -> [LabeledSegment] {
        guard !segments.isEmpty else { return [] }

        // Compute gaps between consecutive segments
        var gaps: [Double] = []
        for i in 1..<segments.count {
            let gap = segments[i].start - segments[i - 1].end
            if gap > 0 {
                gaps.append(gap)
            }
        }

        // Determine threshold: a speaker change requires a gap significantly
        // above the typical pause length
        let threshold: Double
        if gaps.count >= 2 {
            let sorted = gaps.sorted()
            let median = sorted[sorted.count / 2]
            // Speaker change = gap > max(2x median, 2 seconds)
            threshold = max(median * 2.0, 2.0)
        } else {
            threshold = 2.0
        }

        var result: [LabeledSegment] = []
        var currentSpeaker = "Speaker A"

        for (i, seg) in segments.enumerated() {
            if i > 0 {
                let gap = seg.start - segments[i - 1].end
                if gap > threshold {
                    currentSpeaker = (currentSpeaker == "Speaker A") ? "Speaker B" : "Speaker A"
                }
            }
            result.append(LabeledSegment(
                start: seg.start,
                end: seg.end,
                text: seg.text.trimmingCharacters(in: .whitespaces),
                speaker: currentSpeaker
            ))
        }
        return result
    }

    // MARK: - Output Generation

    /// Plain text without speaker labels
    private func generateTXT(_ segments: [WhisperSegment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n") + "\n"
    }

    /// Text with speaker labels, merging consecutive same-speaker segments
    private func generateTXTWithSpeakers(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        var lines: [String] = []
        var currentSpeaker = ""
        var currentText = ""

        for seg in segments {
            if seg.speaker != currentSpeaker {
                if !currentText.isEmpty {
                    lines.append("(\(currentSpeaker)) \(currentText.trimmingCharacters(in: .whitespaces))")
                }
                currentSpeaker = seg.speaker
                currentText = seg.text
            } else {
                currentText += " " + seg.text
            }
        }
        if !currentText.isEmpty {
            lines.append("(\(currentSpeaker)) \(currentText.trimmingCharacters(in: .whitespaces))")
        }

        return lines.joined(separator: "\n\n") + "\n"
    }

    private func generateSRT(_ segments: [WhisperSegment]) -> String {
        var srt = ""
        for (i, seg) in segments.enumerated() {
            srt += "\(i + 1)\n"
            srt += "\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n"
            srt += "\(seg.text.trimmingCharacters(in: .whitespaces))\n\n"
        }
        return srt
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let totalMin = totalSec / 60
        let m = totalMin % 60
        let h = totalMin / 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case noOutput
    case emptyTranscription
    case whisperFailed(exitCode: Int32)
    case modelDownloadFailed(model: String)

    var errorDescription: String? {
        switch self {
        case .noOutput:
            return "Whisper did not produce an output file. Check that the input is a valid audio/video file."
        case .emptyTranscription:
            return "Transcription produced no segments. The file may contain no speech."
        case .whisperFailed(let code):
            return "Whisper exited with code \(code). Check the log output for details."
        case .modelDownloadFailed(let model):
            return "Failed to download the '\(model)' model. Check your internet connection and try again."
        }
    }
}

// MARK: - Line Buffer

final class LineBuffer: @unchecked Sendable {
    private var buffer = ""
    private let onLine: (String) -> Void
    private let lock = NSLock()

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ str: String) {
        lock.lock()
        buffer += str
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            lock.unlock()
            onLine(line)
            lock.lock()
        }
        while let range = buffer.range(of: "\r") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            lock.unlock()
            if !line.isEmpty { onLine(line) }
            lock.lock()
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let remaining = buffer
        buffer = ""
        lock.unlock()
        if !remaining.isEmpty {
            onLine(remaining)
        }
    }
}

// MARK: - Throttled Output

final class ThrottledOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLines: [String] = []
    private var latestEndTime: Double?
    private let interval: TimeInterval
    private let onFlush: ([String], Double?) -> Void
    private var timer: DispatchSourceTimer?

    init(interval: TimeInterval, onFlush: @escaping ([String], Double?) -> Void) {
        self.interval = interval
        self.onFlush = onFlush

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.flush()
        }
        t.resume()
        self.timer = t
    }

    deinit {
        timer?.cancel()
    }

    func addLine(_ line: String) {
        lock.lock()
        pendingLines.append(line)
        lock.unlock()
    }

    func updateEndTime(_ time: Double) {
        lock.lock()
        latestEndTime = time
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let lines = pendingLines
        let endTime = latestEndTime
        pendingLines = []
        lock.unlock()

        if !lines.isEmpty || endTime != nil {
            onFlush(lines, endTime)
        }
    }

    func forceFlush() {
        timer?.cancel()
        timer = nil
        flush()
    }
}
