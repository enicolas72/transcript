import Foundation
import AVFoundation

// MARK: - PCMReader contract

/// Streaming PCM source consumed by `XAIClient.sendPCM`. Each call to
/// `next()` returns up to `AudioExtractor.chunkBytes` of 16 kHz mono
/// PCM16-LE, or `nil` when the source is exhausted.
///
/// Two backends conform: `AVFoundationPCMReader` (the default, hardware-
/// decoded fast path) and `FFmpegPCMReader` (LGPL fallback for containers
/// AVFoundation refuses to open).
protocol PCMReader: AnyObject {
    /// Estimated total PCM bytes the reader will produce. Used by the
    /// progress UI; ±5 % accuracy is fine.
    var totalBytes: Int64 { get }
    /// Backend identifier for logging — either "AVFoundation" or "FFmpeg".
    var backendName: String { get }
    /// Next chunk of PCM, or `nil` at EOF. Throws on irrecoverable
    /// decoder errors.
    func next() throws -> Data?
}

// MARK: - AudioExtractor (dispatcher)

enum AudioExtractor {

    static let sampleRate: Int32 = 16_000
    /// 16-bit mono @ 16 kHz → 32 000 bytes per second of audio.
    static let bytesPerSecond: Int64 = Int64(sampleRate) * 2
    /// WebSocket chunk size. 8000 bytes = 250 ms of audio — a practical
    /// balance: big enough to keep WebSocket frame overhead low (~4 frames
    /// per second of audio), small enough that progress reporting and
    /// pacing stay smooth.
    static let chunkBytes = 8_000

    /// Open `fileURL` for streaming PCM extraction. Tries AVFoundation
    /// first; if that fails (no audio track, unknown container, malformed
    /// codec), falls back to FFmpeg. Throws only when both backends give
    /// up.
    static func openPCMReader(_ fileURL: URL) async throws -> PCMReader {
        do {
            return try await AVFoundationPCMReader.open(fileURL: fileURL)
        } catch {
            // AVFoundation refused — most likely an unsupported container
            // (MKV, WebM, OGG, AVI, WMV, …). Try the FFmpeg fallback.
            return try FFmpegPCMReader(fileURL: fileURL)
        }
    }

    /// Duration in seconds, if it can be determined. Used only for logging.
    static func probeDuration(_ fileURL: URL) async -> Double? {
        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : nil
        } catch {
            return nil
        }
    }
}

// MARK: - AVFoundation backend

/// PCM reader backed by `AVAssetReader`. Handles every container Apple
/// supports natively (MP3, M4A, MP4, MOV, WAV, FLAC, AAC, AIFF, CAF).
final class AVFoundationPCMReader: PCMReader {
    let totalBytes: Int64
    let backendName = "AVFoundation"

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var leftover = Data()
    private var finished = false

    static func open(fileURL: URL) async throws -> AVFoundationPCMReader {
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw TranscriptionError.noOutput }
        let cmDuration = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(cmDuration)
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        return try AVFoundationPCMReader(asset: asset, track: track, durationSeconds: safeDuration)
    }

    fileprivate init(asset: AVAsset, track: AVAssetTrack, durationSeconds: Double) throws {
        self.reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioExtractor.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw TranscriptionError.noOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError.noOutput
        }
        self.totalBytes = Int64(durationSeconds * Double(AudioExtractor.bytesPerSecond))
    }

    func next() throws -> Data? {
        if finished && leftover.isEmpty { return nil }

        while leftover.count < AudioExtractor.chunkBytes && !finished {
            guard let sample = output.copyNextSampleBuffer() else {
                finished = true
                if let err = reader.error { throw err }
                break
            }
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block)
                if length > 0 {
                    var buf = Data(count: length)
                    let status = buf.withUnsafeMutableBytes { raw -> OSStatus in
                        guard let base = raw.baseAddress else { return -1 }
                        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                    }
                    if status == noErr { leftover.append(buf) }
                }
            }
        }

        if leftover.isEmpty { return nil }
        let n = min(AudioExtractor.chunkBytes, leftover.count)
        let chunk = leftover.prefix(n)
        leftover.removeFirst(n)
        return Data(chunk)
    }
}
