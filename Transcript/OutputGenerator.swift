import Foundation

/// Formats `LabeledSegment` sequences into `.txt` and `.srt` files.
enum OutputGenerator {

    // MARK: - TXT

    /// Plain text — one line per server-emitted chunk (transcript.partial
    /// event), preserving the ~3-second cue boundaries. Used when speaker
    /// detection is off.
    static func generateTXT(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        return segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n") + "\n"
    }

    /// Text with speaker labels, merging consecutive same-speaker segments
    /// into a single paragraph.
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

    // MARK: - SRT

    /// One cue per segment, optionally prefixed with the speaker label.
    static func generateSRT(_ segments: [LabeledSegment], withSpeakers: Bool) -> String {
        var srt = ""
        var index = 1
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            srt += "\(index)\n"
            srt += "\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n"
            if withSpeakers && !seg.speaker.isEmpty {
                srt += "(\(seg.speaker)) \(text)\n\n"
            } else {
                srt += "\(text)\n\n"
            }
            index += 1
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
