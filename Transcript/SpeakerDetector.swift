import Foundation

enum SpeakerDetector {
    /// Assign speakers based on pause gaps between segments.
    ///
    /// Heuristic: compute the median gap across all segments, then only toggle
    /// speaker when a gap is significantly larger than the median (2x the median
    /// or at least 2 seconds, whichever is greater). This avoids false positives
    /// from natural within-speaker pauses.
    static func assignSpeakers(_ segments: [WhisperSegment]) -> [LabeledSegment] {
        guard !segments.isEmpty else { return [] }

        var gaps: [Double] = []
        for i in 1..<segments.count {
            let gap = segments[i].start - segments[i - 1].end
            if gap > 0 {
                gaps.append(gap)
            }
        }

        let threshold: Double
        if gaps.count >= 2 {
            let sorted = gaps.sorted()
            let median = sorted[sorted.count / 2]
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
}
