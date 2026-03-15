import Foundation
import FluidAudio

final class DiarizationService: @unchecked Sendable {
    private let manager: OfflineDiarizerManager

    init() {
        manager = OfflineDiarizerManager()
    }

    /// Download CoreML models on first use (cached permanently).
    func ensureModels(
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws {
        onProgress(ProgressUpdate(kind: .status("Preparing diarization models...")))
        onProgress(ProgressUpdate(kind: .log("Downloading/compiling diarization models (first run only)...")))
        try await manager.prepareModels()
        onProgress(ProgressUpdate(kind: .log("Diarization models ready.")))
    }

    /// Run diarization on an audio file.
    func diarize(
        fileURL: URL,
        onProgress: @escaping @Sendable (ProgressUpdate) -> Void
    ) async throws -> [DiarizationSegment] {
        onProgress(ProgressUpdate(kind: .status("Analyzing speakers...")))
        let result = try await manager.process(fileURL)

        // Map FluidAudio's string speaker IDs to sequential integers by first appearance
        var speakerIdMap: [String: Int] = [:]
        var nextId = 0

        return result.segments.map { segment in
            let id: Int
            if let existingId = speakerIdMap[segment.speakerId] {
                id = existingId
            } else {
                id = nextId
                speakerIdMap[segment.speakerId] = nextId
                nextId += 1
            }

            let letter = id < 26 ? String(Character(UnicodeScalar(65 + id)!)) : "\(id + 1)"
            return DiarizationSegment(
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds),
                speakerId: id,
                speakerLabel: "Speaker \(letter)"
            )
        }
    }
}
