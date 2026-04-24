import Foundation

/// Thin orchestrator around the xAI Speech-to-Text streaming WebSocket.
/// Reads the source file as PCM, pipes it through `XAIClient`, groups the
/// word-level results into speaker-coherent `LabeledSegment`s, and writes
/// `.txt` / `.srt`.
struct TranscriptionService {

    func transcribe(
        fileURL: URL,
        outputDir: URL?,
        txtEnabled: Bool,
        srtEnabled: Bool,
        speakerDetection: Bool,
        language: TranscriptLanguage,
        apiKey: String,
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
        log("Opening audio track (PCM16 LE mono @ 16 kHz)")
        let reader = try await AudioExtractor.openPCMReader(fileURL)
        log("Total PCM: \(ByteCountFormatter.string(fromByteCount: reader.totalBytes, countStyle: .binary))")

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
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            txtPath = path
            log("Wrote \(path)")
        }

        if srtEnabled {
            let path = destDir.appendingPathComponent("\(base).srt").path
            let content = OutputGenerator.generateSRT(segments, withSpeakers: speakerDetection)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            srtPath = path
            log("Wrote \(path)")
        }

        onProgress(ProgressUpdate(kind: .progress(1.0)))
        return TranscriptionResult(txtPath: txtPath, srtPath: srtPath)
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
