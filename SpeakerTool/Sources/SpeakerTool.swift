import Foundation
import FluidAudio

// MARK: - Whisper JSON Types

struct WhisperWord: Decodable, Sendable {
    let word: String
    let start: Double
    let end: Double
}

struct WhisperSegmentFull: Decodable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let words: [WhisperWord]?
}

struct WhisperJSON: Decodable, Sendable {
    let segments: [WhisperSegmentFull]
}

// MARK: - Diarization Types

struct DiarSegment: Sendable {
    let start: Double
    let end: Double
    let speakerId: Int
}

// MARK: - Stderr Helper

struct StderrStream: TextOutputStream, @unchecked Sendable {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

nonisolated(unsafe) var stderr = StderrStream()

// MARK: - Entry Point

@main
struct SpeakerTool {
    static func main() async throws {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            printUsage()
            return
        }

        let audioPath = args[1]
        let audioURL = URL(fileURLWithPath: audioPath)

        guard FileManager.default.fileExists(atPath: audioPath) else {
            print("Error: file not found: \(audioPath)", to: &stderr)
            return
        }

        // Run diarization
        let diarSegments = try await runDiarization(audioURL: audioURL)

        // If no whisper JSON, just print diarization segments
        guard args.count >= 3 else {
            printDiarizationSegments(diarSegments)
            return
        }

        // Load whisper JSON and merge
        let jsonPath = args[2]
        let jsonData = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let whisper = try JSONDecoder().decode(WhisperJSON.self, from: jsonData)

        let hasWords = whisper.segments.contains { $0.words != nil && !$0.words!.isEmpty }

        if hasWords {
            print("Using word-level merge", to: &stderr)
            let output = mergeWordLevel(whisper: whisper, diarSegments: diarSegments)
            print(output)
        } else {
            print("Using segment-level merge (no word timestamps available)", to: &stderr)
            let output = mergeSegmentLevel(whisper: whisper, diarSegments: diarSegments)
            print(output)
        }
    }

    // MARK: - Diarization

    static func runDiarization(audioURL: URL) async throws -> [DiarSegment] {
        print("Preparing diarization models...", to: &stderr)

        var config = OfflineDiarizerConfig.default
        // Finer temporal resolution: 1s steps instead of 2s
        config.segmentation.stepRatio = 0.1
        // Capture short interjections (300ms min)
        config.embedding.minSegmentDurationSeconds = 0.3
        // Don't merge nearby segments
        config.postProcessing.minGapDurationSeconds = 0.02
        // More sensitive speaker separation
        config.clustering.threshold = 0.5
        // More sensitive speech boundary detection
        config.segmentation.speechOnsetThreshold = 0.4
        config.segmentation.speechOffsetThreshold = 0.4

        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()

        print("Running diarization on: \(audioURL.lastPathComponent)", to: &stderr)
        let result = try await manager.process(audioURL)

        let uniqueSpeakers = Set(result.segments.map(\.speakerId)).sorted()
        print("Found \(uniqueSpeakers.count) speaker(s): \(uniqueSpeakers.joined(separator: ", "))", to: &stderr)

        // Map string IDs to sequential ints by first appearance
        var speakerIdMap: [String: Int] = [:]
        var nextId = 0

        let segments: [DiarSegment] = result.segments.map { seg in
            let id: Int
            if let existing = speakerIdMap[seg.speakerId] {
                id = existing
            } else {
                id = nextId
                speakerIdMap[seg.speakerId] = nextId
                nextId += 1
            }
            return DiarSegment(
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                speakerId: id
            )
        }

        return segments
    }

    // MARK: - Word-Level Merge

    static func mergeWordLevel(whisper: WhisperJSON, diarSegments: [DiarSegment]) -> String {
        // Flatten all words across segments
        var allWords: [(word: String, start: Double, end: Double)] = []
        for seg in whisper.segments {
            guard let words = seg.words else { continue }
            for w in words {
                allWords.append((word: w.word, start: w.start, end: w.end))
            }
        }

        guard !allWords.isEmpty, !diarSegments.isEmpty else {
            return whisper.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }

        // Assign each word to a speaker
        var labeledWords: [(word: String, speakerId: Int)] = []
        for w in allWords {
            let speakerId = findSpeaker(start: w.start, end: w.end, diarSegments: diarSegments)
            labeledWords.append((word: w.word, speakerId: speakerId))
        }

        // Relabel by first appearance order
        var speakerOrder: [Int: String] = [:]
        var nextLabel = 0
        for lw in labeledWords {
            if speakerOrder[lw.speakerId] == nil {
                let letter = nextLabel < 26 ? String(Character(UnicodeScalar(65 + nextLabel)!)) : "\(nextLabel + 1)"
                speakerOrder[lw.speakerId] = "Speaker \(letter)"
                nextLabel += 1
            }
        }

        // Group consecutive same-speaker words into paragraphs
        var paragraphs: [(speaker: String, text: String)] = []
        var currentSpeaker = ""
        var currentWords: [String] = []

        for lw in labeledWords {
            let label = speakerOrder[lw.speakerId]!
            if label != currentSpeaker {
                if !currentWords.isEmpty {
                    paragraphs.append((speaker: currentSpeaker, text: joinWords(currentWords)))
                }
                currentSpeaker = label
                currentWords = [lw.word]
            } else {
                currentWords.append(lw.word)
            }
        }
        if !currentWords.isEmpty {
            paragraphs.append((speaker: currentSpeaker, text: joinWords(currentWords)))
        }

        return paragraphs.map { "(\($0.speaker)) \($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: - Segment-Level Merge

    static func mergeSegmentLevel(whisper: WhisperJSON, diarSegments: [DiarSegment]) -> String {
        guard !diarSegments.isEmpty else {
            return whisper.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }

        var speakerOrder: [Int: String] = [:]
        var nextLabel = 0

        var paragraphs: [(speaker: String, text: String)] = []
        var currentSpeaker = ""
        var currentText = ""

        for seg in whisper.segments {
            let speakerId = findSpeaker(start: seg.start, end: seg.end, diarSegments: diarSegments)

            if speakerOrder[speakerId] == nil {
                let letter = nextLabel < 26 ? String(Character(UnicodeScalar(65 + nextLabel)!)) : "\(nextLabel + 1)"
                speakerOrder[speakerId] = "Speaker \(letter)"
                nextLabel += 1
            }
            let label = speakerOrder[speakerId]!

            if label != currentSpeaker {
                if !currentText.isEmpty {
                    paragraphs.append((speaker: currentSpeaker, text: currentText.trimmingCharacters(in: .whitespaces)))
                }
                currentSpeaker = label
                currentText = seg.text
            } else {
                currentText += " " + seg.text
            }
        }
        if !currentText.isEmpty {
            paragraphs.append((speaker: currentSpeaker, text: currentText.trimmingCharacters(in: .whitespaces)))
        }

        return paragraphs.map { "(\($0.speaker)) \($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: - Speaker Assignment

    static func findSpeaker(start: Double, end: Double, diarSegments: [DiarSegment]) -> Int {
        // Find overlapping diarization segments, pick the one with most overlap
        var overlapBySpeaker: [Int: Double] = [:]

        for seg in diarSegments {
            let overlapStart = max(start, seg.start)
            let overlapEnd = min(end, seg.end)
            let overlap = overlapEnd - overlapStart
            if overlap > 0 {
                overlapBySpeaker[seg.speakerId, default: 0] += overlap
            }
        }

        if let (speakerId, _) = overlapBySpeaker.max(by: { $0.value < $1.value }) {
            return speakerId
        }

        // No overlap — find nearest segment by midpoint
        let mid = (start + end) / 2
        var nearestId = diarSegments[0].speakerId
        var nearestDist = Double.infinity

        for seg in diarSegments {
            let segMid = (seg.start + seg.end) / 2
            let dist = abs(segMid - mid)
            if dist < nearestDist {
                nearestDist = dist
                nearestId = seg.speakerId
            }
        }
        return nearestId
    }

    // MARK: - Helpers

    static func joinWords(_ words: [String]) -> String {
        var result = ""
        for w in words {
            // Whisper words usually have leading space
            if w.hasPrefix(" ") || result.isEmpty {
                result += w
            } else {
                result += " " + w
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func printDiarizationSegments(_ segments: [DiarSegment]) {
        print("\nDiarization segments (\(segments.count) total):")
        print("---")
        for seg in segments {
            let start = formatTime(seg.start)
            let end = formatTime(seg.end)
            let letter = seg.speakerId < 26 ? String(Character(UnicodeScalar(65 + seg.speakerId)!)) : "\(seg.speakerId + 1)"
            print("[\(start) -> \(end)] Speaker \(letter)")
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 100)
        return String(format: "%d:%02d.%02d", m, s, ms)
    }

    static func printUsage() {
        print("""
        Usage:
          SpeakerTool <audio-file>                    Diarize only (print speaker segments)
          SpeakerTool <audio-file> <whisper-json>     Diarize + merge with whisper output
        """)
    }
}
