import Foundation

/// Thin orchestrator around the xAI Speech-to-Text streaming WebSocket.
/// Reads the source file as PCM, pipes it through `XAIClient`, groups the
/// word-level results into speaker-coherent `LabeledSegment`s, and writes
/// `.txt` / `.srt`.
struct TranscriptionService {

    /// Callback the service invokes when a write to the destination folder
    /// is rejected by the App Sandbox. The host (the GUI ViewModel) is
    /// expected to surface an `NSOpenPanel` pre-pointed at `folder`; the
    /// returned `Bool` indicates whether the user granted access. After
    /// `true`, the service retries the write — the NSOpenPanel grant
    /// extends the sandbox for that folder for the rest of the session.
    typealias WriteAccessRequest = @Sendable (_ folder: URL) async -> Bool

    func transcribe(
        fileURL: URL,
        outputDir: URL?,
        txtEnabled: Bool,
        srtEnabled: Bool,
        speakerDetection: Bool,
        language: TranscriptLanguage,
        apiKey: String,
        requestWriteAccess: WriteAccessRequest? = nil,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> TranscriptionResult {

        guard !apiKey.isEmpty else { throw XAIError.missingAPIKey }

        let log: @Sendable (String) -> Void = { text in
            onProgress(ProgressUpdate(kind: .log(text)))
        }

        log("Start: \(fileURL.lastPathComponent)")

        if let duration = await AudioExtractor.probeDuration(fileURL) {
            let m = Int(duration) / 60
            let s = Int(duration) % 60
            log("File duration: \(m)m\(s)s")
        }

        onProgress(ProgressUpdate(kind: .status("Extracting audio...")))
        onProgress(ProgressUpdate(kind: .progress(0.05)))
        let reader = try AudioExtractor.openPCMReader(fileURL)
        log("Decoded to PCM16 LE mono @ 16 kHz (FFmpeg, \(ByteCountFormatter.string(fromByteCount: reader.totalBytes, countStyle: .binary)))")

        onProgress(ProgressUpdate(kind: .status("Streaming to xAI...")))
        onProgress(ProgressUpdate(kind: .progress(0.10)))
        log("Calling xAI Speech-to-Text (\(language.displayName))…")

        let response = try await XAIClient.streamingTranscribe(
            reader: reader,
            languageCode: language.xAICode,
            diarize: speakerDetection,
            apiKey: apiKey,
            log: log,
            onFinalPartial: { text in
                onProgress(ProgressUpdate(kind: .log("… " + text)))
            },
            onUploadProgress: { sent, total in
                guard total > 0 else { return }
                // Streaming upload occupies 10–85%; the last 15% is for the
                // server's final assembly + file writing.
                let frac = 0.10 + 0.75 * Double(sent) / Double(total)
                onProgress(ProgressUpdate(kind: .progress(frac)))
                if sent >= total {
                    onProgress(ProgressUpdate(kind: .status("Waiting for transcript.done...")))
                }
            }
        )

        log("Transcription complete: \(response.words.count) words")
        onProgress(ProgressUpdate(kind: .progress(0.9)))

        let destDir = outputDir ?? fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        let segments: [LabeledSegment]
        if speakerDetection {
            segments = groupByWordSpeaker(
                words: response.words,
                fallbackText: response.text
            )
        } else {
            segments = mapServerSegments(response.segments, fallbackText: response.text)
        }

        if speakerDetection {
            let speakerCount = Set(segments.map(\.speaker)).count
            log("Detected \(speakerCount) speaker(s) across \(segments.count) segments")
        }

        var txtPath: String? = nil
        var srtPath: String? = nil

        if txtEnabled {
            let path = destDir.appendingPathComponent("\(base).txt").path
            let content = speakerDetection
                ? OutputGenerator.generateTXTWithSpeakers(segments)
                : OutputGenerator.generateTXT(segments)
            try await Self.writeOutput(content, to: path, destDir: destDir, requestWriteAccess: requestWriteAccess)
            txtPath = path
            log("Wrote \(path)")
        }

        if srtEnabled {
            let path = destDir.appendingPathComponent("\(base).srt").path
            let content = OutputGenerator.generateSRT(segments, withSpeakers: speakerDetection)
            try await Self.writeOutput(content, to: path, destDir: destDir, requestWriteAccess: requestWriteAccess)
            srtPath = path
            log("Wrote \(path)")
        }

        onProgress(ProgressUpdate(kind: .progress(1.0)))
        return TranscriptionResult(txtPath: txtPath, srtPath: srtPath)
    }

    // MARK: - Sandbox-aware writes

    /// Wrap `String.write(toFile:)` so that the sandbox denial we get
    /// when writing next to a dropped file becomes:
    /// 1. an attempt to obtain write access via the host's `requestWriteAccess`
    ///    (typically an `NSOpenPanel` pre-pointed at the folder), then
    /// 2. a retry of the write inside the freshly-extended sandbox scope, or
    /// 3. our user-friendly `outputPermissionDenied` if the user declined.
    private static func writeOutput(
        _ content: String,
        to path: String,
        destDir: URL,
        requestWriteAccess: WriteAccessRequest?
    ) async throws {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                                        && error.code == NSFileWriteNoPermissionError {
            // Sandbox denied the write. Ask the host UI for permission.
            if let request = requestWriteAccess, await request(destDir) {
                // NSOpenPanel grant extends the sandbox for this folder for
                // the lifetime of the app, so a plain retry should now work.
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
            throw TranscriptionError.outputPermissionDenied(folder: destDir.path)
        }
    }

    // MARK: - Segment construction

    /// Non-diarized path: one `LabeledSegment` per server-emitted chunk-final
    /// `transcript.partial` event. This preserves the natural ~3-second
    /// speech chunking that the API produces; each becomes one SRT cue and
    /// one TXT paragraph.
    private func mapServerSegments(
        _ segments: [XAIClient.Segment],
        fallbackText: String
    ) -> [LabeledSegment] {
        if !segments.isEmpty {
            return segments
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { LabeledSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: ""
                )}
        }
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [LabeledSegment(start: 0, end: 0, text: trimmed, speaker: "")]
    }

    /// Diarized path (currently unused — xAI streaming diarization OOMs as
    /// of 2026-04-22): group consecutive same-speaker words into segments.
    /// Kept so we can flip back on once xAI ships a fix.
    private func groupByWordSpeaker(
        words: [XAIClient.Word],
        fallbackText: String
    ) -> [LabeledSegment] {
        guard !words.isEmpty else {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [LabeledSegment(start: 0, end: 0, text: trimmed, speaker: "")]
        }

        var speakerLabels: [Int: String] = [:]
        var nextLabelIndex = 0
        func label(for id: Int?) -> String {
            guard let id else { return "" }
            if let existing = speakerLabels[id] { return existing }
            let letter: String
            if nextLabelIndex < 26 {
                letter = String(Character(UnicodeScalar(65 + nextLabelIndex)!))
            } else {
                letter = "\(nextLabelIndex + 1)"
            }
            let name = "Speaker \(letter)"
            speakerLabels[id] = name
            nextLabelIndex += 1
            return name
        }

        var segments: [LabeledSegment] = []
        var currentSpeaker = label(for: words[0].speaker)
        var currentStart = words[0].start
        var currentEnd = words[0].end
        var currentText = ""

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            segments.append(LabeledSegment(
                start: currentStart, end: currentEnd,
                text: trimmed, speaker: currentSpeaker))
        }

        for (i, w) in words.enumerated() {
            let wSpeaker = label(for: w.speaker)
            if i > 0 && wSpeaker != currentSpeaker {
                flush()
                currentSpeaker = wSpeaker
                currentStart = w.start
                currentText = ""
            }
            if !currentText.isEmpty && !w.text.hasPrefix(" ") && !currentText.hasSuffix(" ") {
                currentText += " "
            }
            currentText += w.text
            currentEnd = w.end
        }
        flush()
        return segments
    }
}

extension TranscriptLanguage {
    /// Value for xAI's `language=` query param.
    var xAICode: String { rawValue }
}
