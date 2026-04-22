import Foundation
import AVFoundation

/// Streams PCM16 LE mono @ 16 kHz out of any AVFoundation-supported file.
/// Used by the streaming xAI WebSocket client — we never hold the whole
/// audio in memory, just one chunk at a time.
enum AudioExtractor {

    static let sampleRate: Int32 = 16_000
    /// 16-bit mono @ 16 kHz → 32 000 bytes per second of audio.
    static let bytesPerSecond: Int64 = Int64(sampleRate) * 2
    /// WebSocket chunk size. 8000 bytes = 250 ms of audio — a practical
    /// balance: big enough to keep WebSocket frame overhead low (~4 frames
    /// per second of audio), small enough that progress reporting and
    /// pacing stay smooth.
    static let chunkBytes = 8_000

    /// Reader over an audio asset. Pull successive `next()` until it returns
    /// nil; each call gives a PCM16 LE chunk of up to `chunkBytes` bytes.
    final class PCMReader {
        let totalBytes: Int64
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private var leftover = Data()
        private var finished = false

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

        /// Next PCM chunk, or nil when the source is exhausted.
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

    /// Open `fileURL` for streaming PCM extraction. Throws if the file has no
    /// audio track. The returned reader's `totalBytes` is a good upload-size
    /// estimate for progress reporting.
    static func openPCMReader(_ fileURL: URL) async throws -> PCMReader {
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw TranscriptionError.noOutput }
        let cmDuration = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(cmDuration)
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        return try PCMReader(asset: asset, track: track, durationSeconds: safeDuration)
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
