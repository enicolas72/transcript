import Foundation

enum OutputGenerator {
    /// Plain text without speaker labels
    static func generateTXT(_ segments: [WhisperSegment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n") + "\n"
    }

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

    /// Standard SRT subtitle format
    static func generateSRT(_ segments: [WhisperSegment]) -> String {
        var srt = ""
        for (i, seg) in segments.enumerated() {
            srt += "\(i + 1)\n"
            srt += "\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n"
            srt += "\(seg.text.trimmingCharacters(in: .whitespaces))\n\n"
        }
        return srt
    }

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
