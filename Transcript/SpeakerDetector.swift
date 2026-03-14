import Foundation

enum SpeakerDetector {
    /// Assign speakers using voice feature analysis.
    ///
    /// Extracts audio, computes spectral voice features per segment
    /// (spectral centroid, spread, energy, zero-crossing rate, pitch),
    /// and clusters into 2 speakers using k-means.
    static func assignSpeakers(
        filePath: String,
        segments: [WhisperSegment]
    ) async -> [LabeledSegment] {
        await VoiceAnalyzer.assignSpeakers(filePath: filePath, segments: segments)
    }
}
