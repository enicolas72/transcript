import Foundation
import FluidAudio

/// Merges ASR tokens with speaker detection using per-sub-segment neural embeddings.
///
/// This is the orchestrator — it converts TokenTiming (FluidAudio) to TimedWord
/// at the boundary, then delegates to SpeakerEmbedding (CoreML) and
/// SpeakerClustering (pure math). All internal processing uses TimedWord.
enum TranscriptMerger {

    // MARK: - Public API (FluidAudio boundary)

    static func merge(
        tokens: [TokenTiming],
        audioSamples: [Float]
    ) throws -> [LabeledSegment] {
        guard !tokens.isEmpty else { return [] }

        // Convert to our own type at the boundary
        let words = tokens.map { TimedWord(word: $0.token, startTime: $0.startTime, endTime: $0.endTime) }

        // Load WeSpeaker CoreML models
        let models = try SpeakerEmbedding.loadModels()

        // Split words into sub-segments at sentence punctuation
        let subs = splitAtPunctuation(words)

        // Compute one neural embedding per sub-segment
        var subEmbeddings: [[Float]] = []
        for sub in subs {
            guard let first = sub.first, let last = sub.last else { continue }
            let emb = try SpeakerEmbedding.computeEmbedding(
                models: models,
                audioSamples: audioSamples,
                startTime: first.startTime,
                endTime: last.endTime
            )
            subEmbeddings.append(emb)
        }

        // Cluster sub-segment embeddings into speakers
        let (labels, _) = SpeakerClustering.clusterEmbeddings(subEmbeddings, maxSpeakers: 6)

        // Build labeled words with confidence
        var labeledWords: [(word: TimedWord, speaker: Int, confidence: Double)] = []
        for (i, sub) in subs.enumerated() {
            let conf = SpeakerClustering.clusterConfidence(subEmbeddings[i], allEmbeddings: subEmbeddings, labels: labels)
            for w in sub {
                labeledWords.append((word: w, speaker: labels[i], confidence: conf))
            }
        }

        // Post-process: continuation carrying + smoothing
        labeledWords = carryAcrossContinuations(labeledWords, subs: subs)
        labeledWords = smoothRuns(labeledWords, minRun: 5)

        // Reorder by first appearance and build output
        return buildOutput(labeledWords)
    }

    // MARK: - Punctuation Splitting

    static func splitAtPunctuation(_ words: [TimedWord], minWords: Int = 3) -> [[TimedWord]] {
        var subs: [[TimedWord]] = []
        var current: [TimedWord] = []

        for w in words {
            current.append(w)
            let text = w.word.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") {
                if current.count >= minWords {
                    subs.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty {
            if subs.isEmpty || current.count >= minWords {
                subs.append(current)
            } else {
                subs[subs.count - 1].append(contentsOf: current)
            }
        }
        return subs.isEmpty ? [words] : subs
    }

    // MARK: - Continuation Carrying

    static func carryAcrossContinuations(
        _ labeled: [(word: TimedWord, speaker: Int, confidence: Double)],
        subs: [[TimedWord]]
    ) -> [(word: TimedWord, speaker: Int, confidence: Double)] {
        var result = labeled
        let confs = result.map(\.confidence)
        let medianConf = confs.sorted()[confs.count / 2]

        var tokenIdx = 0
        var prevSpeaker: Int? = nil
        var prevEndedWithPunct = true

        for sub in subs {
            let subLen = sub.count
            guard tokenIdx < result.count else { break }

            if !prevEndedWithPunct, let prev = prevSpeaker {
                let subConf = result[tokenIdx].confidence
                if subConf < medianConf {
                    for i in tokenIdx..<min(tokenIdx + subLen, result.count) {
                        result[i].speaker = prev
                    }
                }
            }

            prevSpeaker = result[tokenIdx].speaker
            let lastText = sub.last?.word.trimmingCharacters(in: .whitespaces) ?? ""
            prevEndedWithPunct = lastText.hasSuffix(".") || lastText.hasSuffix("?") || lastText.hasSuffix("!")
            tokenIdx += subLen
        }
        return result
    }

    // MARK: - Smoothing

    static func smoothRuns(
        _ labeled: [(word: TimedWord, speaker: Int, confidence: Double)],
        minRun: Int
    ) -> [(word: TimedWord, speaker: Int, confidence: Double)] {
        var result = labeled
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < result.count {
                var j = i
                while j < result.count && result[j].speaker == result[i].speaker { j += 1 }
                // Only absorb interior short runs. Absorbing boundary runs
                // (i == 0 or j == count) cascades wrongly when several
                // adjacent runs are all below threshold: the first boundary
                // run flips into the next speaker, and subsequent passes
                // propagate the flip across the whole array.
                if j - i < minRun && i > 0 && j < result.count {
                    let absorb = result[i - 1].speaker
                    for k in i..<j { result[k].speaker = absorb }
                    changed = true
                }
                i = j
            }
        }
        return result
    }

    // MARK: - Output Building

    static func buildOutput(
        _ labeled: [(word: TimedWord, speaker: Int, confidence: Double)]
    ) -> [LabeledSegment] {
        var speakerOrder: [Int: String] = [:]
        var nextLabel = 0
        for lt in labeled {
            if speakerOrder[lt.speaker] == nil {
                let letter = nextLabel < 26 ? String(Character(UnicodeScalar(65 + nextLabel)!)) : "\(nextLabel + 1)"
                speakerOrder[lt.speaker] = "Speaker \(letter)"
                nextLabel += 1
            }
        }

        var result: [LabeledSegment] = []
        var currentSpeaker = ""
        var currentText = ""
        var segStart = 0.0
        var segEnd = 0.0

        for lt in labeled {
            let label = speakerOrder[lt.speaker] ?? "Speaker A"
            if label != currentSpeaker {
                if !currentText.isEmpty {
                    result.append(LabeledSegment(start: segStart, end: segEnd,
                        text: currentText.trimmingCharacters(in: .whitespaces), speaker: currentSpeaker))
                }
                currentSpeaker = label
                currentText = lt.word.word
                segStart = lt.word.startTime
            } else {
                currentText += lt.word.word
            }
            segEnd = lt.word.endTime
        }
        if !currentText.isEmpty {
            result.append(LabeledSegment(start: segStart, end: segEnd,
                text: currentText.trimmingCharacters(in: .whitespaces), speaker: currentSpeaker))
        }
        return result
    }
}
