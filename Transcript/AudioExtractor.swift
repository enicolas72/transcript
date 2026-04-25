import Foundation
import AVFoundation

/// Thin namespace for the audio-decoding entry points used by the
/// transcription service. The actual demux + decode + resample work is in
/// `FFmpegPCMReader` — we use FFmpeg for every file, full stop. AVFoundation
/// is only used here to probe the duration cheaply for the log line.
enum AudioExtractor {

    static let sampleRate: Int32 = 16_000
    /// 16-bit mono @ 16 kHz → 32 000 bytes per second of audio.
    static let bytesPerSecond: Int64 = Int64(sampleRate) * 2
    /// WebSocket chunk size. 8000 bytes = 250 ms of audio — a practical
    /// balance: big enough to keep WebSocket frame overhead low (~4 frames
    /// per second of audio), small enough that progress reporting and
    /// pacing stay smooth.
    static let chunkBytes = 8_000

    /// Open `fileURL` for streaming PCM extraction. Always uses the
    /// embedded LGPL FFmpeg build (`Vendor/FFmpeg.xcframework`), which
    /// covers every container / audio codec we need (a strict superset of
    /// what AVFoundation handles natively, plus MKV, WebM, OGG/Opus, AVI,
    /// WMV, WMA, …).
    static func openPCMReader(_ fileURL: URL) throws -> FFmpegPCMReader {
        try FFmpegPCMReader(fileURL: fileURL)
    }

    /// Duration in seconds, if it can be determined. Used only for logging.
    /// AVFoundation's duration probe is fast (just reads the container
    /// header) and accurate on every container we accept.
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
