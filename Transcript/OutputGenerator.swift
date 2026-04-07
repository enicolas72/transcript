import Foundation
import FluidAudio

enum OutputGenerator {

    // MARK: - Token-based outputs (native ASR)

    /// Plain text from ASR tokens
    static func generateTXTFromTokens(_ tokens: [TokenTiming]) -> String {
        tokens.map(\.token).joined().trimmingCharacters(in: .whitespaces) + "\n"
    }

    /// SRT subtitles from ASR tokens, grouped into ~5-second chunks at sentence boundaries
    static func generateSRTFromTokens(_ tokens: [TokenTiming]) -> String {
        let segments = groupTokensIntoSegments(tokens, maxDuration: 5.0)
        var srt = ""
        for (i, seg) in segments.enumerated() {
            srt += "\(i + 1)\n"
            srt += "\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n"
            srt += "\(seg.text.trimmingCharacters(in: .whitespaces))\n\n"
        }
        return srt
    }

    /// Group tokens into subtitle-sized segments, preferring sentence boundaries
    private static func groupTokensIntoSegments(
        _ tokens: [TokenTiming], maxDuration: Double
    ) -> [(start: Double, end: Double, text: String)] {
        guard !tokens.isEmpty else { return [] }

        var segments: [(start: Double, end: Double, text: String)] = []
        var currentStart = tokens[0].startTime
        var currentText = ""
        var lastEnd = tokens[0].startTime

        for token in tokens {
            currentText += token.token
            lastEnd = token.endTime

            let duration = lastEnd - currentStart
            let word = token.token.trimmingCharacters(in: .whitespaces)
            let atSentenceEnd = word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")

            if duration >= maxDuration && atSentenceEnd {
                segments.append((start: currentStart, end: lastEnd,
                    text: currentText.trimmingCharacters(in: .whitespaces)))
                currentText = ""
                currentStart = lastEnd
            }
        }
        if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
            segments.append((start: currentStart, end: lastEnd,
                text: currentText.trimmingCharacters(in: .whitespaces)))
        }
        return segments
    }

    // MARK: - Speaker-labeled output

    /// Text with speaker labels, merging consecutive same-speaker segments
    static func generateTXTWithSpeakers(_ segments: [LabeledSegment]) -> String {
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

    // MARK: - Segment-based outputs (Qwen3 / non-English path)

    /// Plain text from labeled segments — no speaker prefixes.
    /// Used when speaker detection is off in the Qwen3 pipeline.
    static func generateTXTFromSegments(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        return segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ") + "\n"
    }

    /// SRT subtitles from labeled segments — one cue per turn, prefixed with
    /// the speaker label. The Qwen3 pipeline does not produce word timestamps,
    /// so cue boundaries are necessarily turn-level (typically a few seconds
    /// to a minute).
    static func generateSRTFromSegments(_ segments: [LabeledSegment]) -> String {
        var srt = ""
        var index = 1
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            srt += "\(index)\n"
            srt += "\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n"
            if seg.speaker.isEmpty {
                srt += "\(text)\n\n"
            } else {
                srt += "(\(seg.speaker)) \(text)\n\n"
            }
            index += 1
        }
        return srt
    }

    // MARK: - SRT Formatting

    private static func formatSRTTime(_ seconds: Double) -> String {
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
