import XCTest
@testable import Transcript

/// Integration tests for the FFmpeg fallback decoder. Each fixture is a
/// 2-second 8 kHz mono sine wave, encoded with a different (non-AVFoundation)
/// codec/container. The decoder is expected to produce ~64 KB of PCM16 LE
/// (2 s × 16 kHz × 2 bytes/sample = 64 000 bytes), within ±10 % to allow
/// for codec encoder/decoder padding and boundary effects.
final class FFmpegPCMReaderTests: XCTestCase {

    /// Sample rate × bytes-per-sample × duration → expected PCM byte count.
    /// 2 s @ 16 kHz mono S16 = 64 000 bytes.
    private let expectedBytes = 16_000 * 2 * 2
    private let tolerance = 0.10

    func testDecodesMatroskaAAC() throws {
        try expectChunkedPCM(fixture: "sine", ext: "mkv")
    }

    func testDecodesWebMOpus() throws {
        try expectChunkedPCM(fixture: "sine", ext: "webm")
    }

    func testDecodesOggOpus() throws {
        try expectChunkedPCM(fixture: "sine", ext: "ogg")
    }

    /// Sanity check that the FFmpeg path also handles what AVFoundation
    /// used to handle natively, now that we've dropped the AVFoundation
    /// backend. MP3 → Matroska/AAC etc. are all the same code path.
    func testDecodesMP3() throws {
        try expectChunkedPCM(fixture: "sine", ext: "mp3")
    }

    // MARK: - Helpers

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        // The bundle resource lookup falls back to the source-tree path so
        // that fixtures don't need to be re-listed in the Resources phase
        // for every developer.
        if let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle(for: type(of: self)).url(forResource: name, withExtension: ext) {
            return url
        }
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidate = here.appendingPathComponent("Fixtures").appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        throw XCTSkip("Fixture \(name).\(ext) not found at \(candidate.path)")
    }

    private func expectChunkedPCM(fixture: String, ext: String) throws {
        let url = try fixtureURL(fixture, ext)
        let reader = try FFmpegPCMReader(fileURL: url)

        var totalBytes = 0
        var chunkCount = 0
        while let chunk = try reader.next() {
            XCTAssertGreaterThan(chunk.count, 0)
            XCTAssertLessThanOrEqual(chunk.count, AudioExtractor.chunkBytes)
            totalBytes += chunk.count
            chunkCount += 1
            // Even chunk sizes — required for S16 alignment.
            XCTAssertEqual(chunk.count % 2, 0, "PCM16 chunks must be byte-aligned")
        }

        XCTAssertGreaterThan(chunkCount, 0, "\(fixture).\(ext): no chunks produced")
        let lower = Double(expectedBytes) * (1 - tolerance)
        let upper = Double(expectedBytes) * (1 + tolerance)
        XCTAssert(
            (lower...upper).contains(Double(totalBytes)),
            "\(fixture).\(ext): expected ~\(expectedBytes) bytes (±10 %), got \(totalBytes)"
        )
    }
}
