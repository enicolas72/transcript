import XCTest
@testable import Transcript

final class OutputGeneratorTests: XCTestCase {

    // MARK: - generateTXTWithSpeakers

    func testTXTWithSpeakersSingleSpeaker() {
        let segments = [
            LabeledSegment(start: 0, end: 5, text: "Hello world.", speaker: "Speaker A"),
            LabeledSegment(start: 5, end: 10, text: "How are you?", speaker: "Speaker A"),
        ]
        let result = OutputGenerator.generateTXTWithSpeakers(segments)
        XCTAssertEqual(result, "(Speaker A) Hello world. How are you?\n")
    }

    func testTXTWithSpeakersMultipleSpeakers() {
        let segments = [
            LabeledSegment(start: 0, end: 3, text: "Hi there.", speaker: "Speaker A"),
            LabeledSegment(start: 3, end: 6, text: "Hey!", speaker: "Speaker B"),
            LabeledSegment(start: 6, end: 9, text: "How's it going?", speaker: "Speaker A"),
        ]
        let result = OutputGenerator.generateTXTWithSpeakers(segments)
        let expected = "(Speaker A) Hi there.\n\n(Speaker B) Hey!\n\n(Speaker A) How's it going?\n"
        XCTAssertEqual(result, expected)
    }

    func testTXTWithSpeakersEmpty() {
        let result = OutputGenerator.generateTXTWithSpeakers([])
        XCTAssertEqual(result, "")
    }

    func testTXTWithSpeakersMergesConsecutiveSameSpeaker() {
        let segments = [
            LabeledSegment(start: 0, end: 2, text: "First.", speaker: "Speaker A"),
            LabeledSegment(start: 2, end: 4, text: "Second.", speaker: "Speaker A"),
            LabeledSegment(start: 4, end: 6, text: "Third.", speaker: "Speaker A"),
        ]
        let result = OutputGenerator.generateTXTWithSpeakers(segments)
        // All same speaker, should merge into one paragraph
        XCTAssertEqual(result, "(Speaker A) First. Second. Third.\n")
    }

    // MARK: - generateTXT (no speakers)

    func testTXTJoinsSegmentsWithNewlines() {
        let segments = [
            LabeledSegment(start: 0, end: 3, text: "Hello world.", speaker: ""),
            LabeledSegment(start: 3, end: 6, text: "How are you?", speaker: ""),
            LabeledSegment(start: 6, end: 8, text: "Fine thanks.", speaker: ""),
        ]
        let result = OutputGenerator.generateTXT(segments)
        XCTAssertEqual(result, "Hello world.\nHow are you?\nFine thanks.\n")
    }

    func testTXTEmptyYieldsEmptyString() {
        XCTAssertEqual(OutputGenerator.generateTXT([]), "")
    }

    // MARK: - generateSRT

    func testSRTSingleCueFormat() {
        let segments = [
            LabeledSegment(start: 0.0, end: 2.5, text: "Hello world.", speaker: ""),
        ]
        let result = OutputGenerator.generateSRT(segments, withSpeakers: false)
        XCTAssertEqual(result, "1\n00:00:00,000 --> 00:00:02,500\nHello world.\n\n")
    }

    func testSRTMultipleCuesAreNumberedSequentially() {
        let segments = [
            LabeledSegment(start: 0, end: 1.234, text: "First.", speaker: ""),
            LabeledSegment(start: 1.5, end: 4.0, text: "Second.", speaker: ""),
            LabeledSegment(start: 5.0, end: 7.5, text: "Third.", speaker: ""),
        ]
        let result = OutputGenerator.generateSRT(segments, withSpeakers: false)
        XCTAssertTrue(result.contains("1\n00:00:00,000 --> 00:00:01,234\nFirst."))
        XCTAssertTrue(result.contains("2\n00:00:01,500 --> 00:00:04,000\nSecond."))
        XCTAssertTrue(result.contains("3\n00:00:05,000 --> 00:00:07,500\nThird."))
    }

    func testSRTTimestampFormatHandlesHoursMinutesSecondsMs() {
        // 3661.5 s = 1 h 1 min 1 s 500 ms
        let segments = [
            LabeledSegment(start: 3661.5, end: 3661.999, text: "X", speaker: ""),
        ]
        let result = OutputGenerator.generateSRT(segments, withSpeakers: false)
        XCTAssertTrue(result.contains("01:01:01,500 --> 01:01:01,999"),
                      "SRT timestamps should be HH:MM:SS,mmm; got: \(result)")
    }

    func testSRTPrefixesSpeakerLabelWhenRequested() {
        let segments = [
            LabeledSegment(start: 0, end: 2, text: "Hi.", speaker: "Speaker A"),
            LabeledSegment(start: 2, end: 4, text: "Hello.", speaker: "Speaker B"),
        ]
        let result = OutputGenerator.generateSRT(segments, withSpeakers: true)
        XCTAssertTrue(result.contains("(Speaker A) Hi."))
        XCTAssertTrue(result.contains("(Speaker B) Hello."))
    }

    func testSRTOmitsSpeakerPrefixWhenDisabled() {
        // Even if segments carry a speaker label, withSpeakers=false drops it.
        let segments = [
            LabeledSegment(start: 0, end: 2, text: "Hi.", speaker: "Speaker A"),
        ]
        let result = OutputGenerator.generateSRT(segments, withSpeakers: false)
        XCTAssertFalse(result.contains("Speaker A"))
        XCTAssertTrue(result.contains("Hi."))
    }

    func testSRTSkipsSegmentsWithEmptyText() {
        let segments = [
            LabeledSegment(start: 0, end: 1, text: "", speaker: ""),
            LabeledSegment(start: 1, end: 2, text: "Real cue.", speaker: ""),
            LabeledSegment(start: 2, end: 3, text: "   ", speaker: ""),
        ]
        let result = OutputGenerator.generateSRT(segments, withSpeakers: false)
        // Only one surviving cue, numbered 1.
        XCTAssertTrue(result.hasPrefix("1\n"))
        XCTAssertTrue(result.contains("Real cue."))
        XCTAssertFalse(result.contains("2\n"))
    }

    // MARK: - TranscriptLanguage.xAICode

    func testLanguageCodeForEnglish() {
        XCTAssertEqual(TranscriptLanguage.english.xAICode, "en")
    }

    func testLanguageCodeForAutoIsExplicit() {
        // xAI streaming rejects the handshake if `language` is missing, so
        // Automatic is sent as the literal "auto" string (not nil).
        XCTAssertEqual(TranscriptLanguage.auto.xAICode, "auto")
    }

    func testLanguageCodeForFrench() {
        XCTAssertEqual(TranscriptLanguage.french.xAICode, "fr")
    }
}
