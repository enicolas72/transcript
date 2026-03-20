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
}
