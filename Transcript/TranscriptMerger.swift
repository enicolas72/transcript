import Foundation

enum TranscriptMerger {
    /// Merge Whisper text segments with FluidAudio speaker diarization.
    ///
    /// For each Whisper segment, finds overlapping diarization segments and assigns
    /// the speaker with the greatest overlap duration. Labels speakers alphabetically
    /// by first appearance order in the transcript.
    static func merge(
        whisperSegments: [WhisperSegment],
        diarizationSegments: [DiarizationSegment]
    ) -> [LabeledSegment] {
        guard !diarizationSegments.isEmpty else {
            return whisperSegments.map {
                LabeledSegment(start: $0.start, end: $0.end,
                    text: $0.text.trimmingCharacters(in: .whitespaces),
                    speaker: "Speaker A")
            }
        }

        var speakerOrder: [Int: String] = [:]
        var nextLabel = 0

        return whisperSegments.map { whisper in
            let speakerId = findDominantSpeaker(
                whisperStart: whisper.start,
                whisperEnd: whisper.end,
                diarizationSegments: diarizationSegments
            )

            let label: String
            if let existing = speakerOrder[speakerId] {
                label = existing
            } else {
                let letter = nextLabel < 26
                    ? String(Character(UnicodeScalar(65 + nextLabel)!))
                    : "\(nextLabel + 1)"
                label = "Speaker \(letter)"
                speakerOrder[speakerId] = label
                nextLabel += 1
            }

            return LabeledSegment(
                start: whisper.start,
                end: whisper.end,
                text: whisper.text.trimmingCharacters(in: .whitespaces),
                speaker: label
            )
        }
    }

    /// Find the speaker with the most overlap for a given time range.
    /// Falls back to nearest diarization segment if no overlap exists.
    private static func findDominantSpeaker(
        whisperStart: Double,
        whisperEnd: Double,
        diarizationSegments: [DiarizationSegment]
    ) -> Int {
        var overlapBySpeaker: [Int: Double] = [:]

        for seg in diarizationSegments {
            let overlapStart = max(whisperStart, seg.start)
            let overlapEnd = min(whisperEnd, seg.end)
            let overlap = overlapEnd - overlapStart

            if overlap > 0 {
                overlapBySpeaker[seg.speakerId, default: 0] += overlap
            }
        }

        if let (speakerId, _) = overlapBySpeaker.max(by: { $0.value < $1.value }) {
            return speakerId
        }

        // No overlap — inherit from nearest diarization segment
        var nearestId = diarizationSegments[0].speakerId
        var nearestDistance = Double.infinity
        let whisperMid = (whisperStart + whisperEnd) / 2

        for seg in diarizationSegments {
            let segMid = (seg.start + seg.end) / 2
            let dist = abs(segMid - whisperMid)
            if dist < nearestDistance {
                nearestDistance = dist
                nearestId = seg.speakerId
            }
        }

        return nearestId
    }
}
