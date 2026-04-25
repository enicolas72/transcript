import Foundation
import CFFmpeg

/// PCM reader backed by FFmpeg (libavformat / libavcodec / libswresample).
/// Used for every input file — the LGPL-only audio-decoder XCFramework at
/// `Vendor/FFmpeg.xcframework` is a strict superset of what AVFoundation
/// can open.
///
/// Decodes any audio stream the build supports (see
/// `scripts/build-ffmpeg.sh` for the enabled demuxer/decoder list),
/// resamples to 16 kHz mono PCM16-LE via libswresample, and yields it in
/// fixed-size chunks suitable for streaming over the xAI WebSocket.
final class FFmpegPCMReader {
    private(set) var totalBytes: Int64 = 0

    private var formatContext: UnsafeMutablePointer<AVFormatContext>? = nil
    private var codecContext: UnsafeMutablePointer<AVCodecContext>? = nil
    private var swrContext: OpaquePointer? = nil
    private var packet: UnsafeMutablePointer<AVPacket>? = nil
    private var frame: UnsafeMutablePointer<AVFrame>? = nil
    private var audioStreamIndex: Int32 = -1

    private var leftover = Data()
    /// The decoder/resampler has been fully drained; only `leftover` left.
    private var fullyDrained = false
    /// We've sent the EOF flush packet to the decoder.
    private var sentEOF = false

    init(fileURL: URL) throws {
        // 1. Open the input container.
        var fmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var ret = avformat_open_input(&fmt, fileURL.path, nil, nil)
        guard ret == 0, let fmtCtx = fmt else {
            throw TranscriptionError.unsupportedFormat(
                url: fileURL,
                detail: "avformat_open_input: \(Self.ffmpegError(ret))"
            )
        }
        self.formatContext = fmtCtx

        // RAII-style early-throw cleanup. If we throw before the end of init,
        // tear down what we've allocated.
        var initialised = false
        defer { if !initialised { self.cleanup() } }

        // 2. Probe streams (some containers, e.g. MKV without a header table,
        // need the full scan to find the audio codec).
        ret = avformat_find_stream_info(fmtCtx, nil)
        guard ret >= 0 else {
            throw TranscriptionError.unsupportedFormat(
                url: fileURL,
                detail: "avformat_find_stream_info: \(Self.ffmpegError(ret))"
            )
        }

        // 3. Pick the best audio stream.
        var codec: UnsafePointer<AVCodec>? = nil
        let streamIdx = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0)
        guard streamIdx >= 0, let foundCodec = codec else {
            throw TranscriptionError.noOutput
        }
        self.audioStreamIndex = streamIdx

        // 4. Build the codec context.
        guard let codecCtx = avcodec_alloc_context3(foundCodec) else {
            throw TranscriptionError.unsupportedFormat(url: fileURL, detail: "avcodec_alloc_context3 failed")
        }
        self.codecContext = codecCtx

        guard let streamPtr = fmtCtx.pointee.streams[Int(streamIdx)] else {
            throw TranscriptionError.noOutput
        }
        ret = avcodec_parameters_to_context(codecCtx, streamPtr.pointee.codecpar)
        guard ret >= 0 else {
            throw TranscriptionError.unsupportedFormat(
                url: fileURL,
                detail: "avcodec_parameters_to_context: \(Self.ffmpegError(ret))"
            )
        }
        ret = avcodec_open2(codecCtx, foundCodec, nil)
        guard ret == 0 else {
            throw TranscriptionError.unsupportedFormat(
                url: fileURL,
                detail: "avcodec_open2: \(Self.ffmpegError(ret))"
            )
        }

        // 5. Configure libswresample for: input = stream's native layout,
        //    output = mono / 16 kHz / S16-interleaved.
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 1)
        defer { av_channel_layout_uninit(&outLayout) }

        var swr: OpaquePointer? = nil
        ret = swr_alloc_set_opts2(
            &swr,
            &outLayout,
            AV_SAMPLE_FMT_S16,
            AudioExtractor.sampleRate,
            &codecCtx.pointee.ch_layout,
            codecCtx.pointee.sample_fmt,
            codecCtx.pointee.sample_rate,
            0, nil
        )
        guard ret >= 0, let swrCtx = swr else {
            throw TranscriptionError.unsupportedFormat(
                url: fileURL,
                detail: "swr_alloc_set_opts2: \(Self.ffmpegError(ret))"
            )
        }
        self.swrContext = swrCtx
        ret = swr_init(swrCtx)
        guard ret >= 0 else {
            throw TranscriptionError.unsupportedFormat(
                url: fileURL,
                detail: "swr_init: \(Self.ffmpegError(ret))"
            )
        }

        // 6. Allocate the per-frame scratch.
        guard let pkt = av_packet_alloc(), let frm = av_frame_alloc() else {
            throw TranscriptionError.unsupportedFormat(url: fileURL, detail: "av_*_alloc failed")
        }
        self.packet = pkt
        self.frame = frm

        // 7. Estimate total output bytes for progress UI. Prefer the
        //    container duration; fall back to the audio stream's own.
        let durationSec: Double
        if fmtCtx.pointee.duration > 0 {
            durationSec = Double(fmtCtx.pointee.duration) / 1_000_000.0  // AV_TIME_BASE = 1e6
        } else if streamPtr.pointee.duration > 0 {
            let tb = streamPtr.pointee.time_base
            durationSec = Double(streamPtr.pointee.duration) * Double(tb.num) / Double(tb.den)
        } else {
            durationSec = 0
        }
        self.totalBytes = Int64(max(0, durationSec) * Double(AudioExtractor.bytesPerSecond))

        initialised = true
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        if let p = packet { var p = Optional(p); av_packet_free(&p) }
        if let f = frame { var f = Optional(f); av_frame_free(&f) }
        if let s = swrContext { var s = Optional(s); swr_free(&s) }
        if let c = codecContext { var c = Optional(c); avcodec_free_context(&c) }
        if let f = formatContext { var f = Optional(f); avformat_close_input(&f) }
        packet = nil
        frame = nil
        swrContext = nil
        codecContext = nil
        formatContext = nil
    }

    func next() throws -> Data? {
        // Pump packets/frames until we have at least chunkBytes buffered,
        // or we've fully drained the decoder.
        while leftover.count < AudioExtractor.chunkBytes && !fullyDrained {
            try pumpOnce()
        }
        if leftover.isEmpty { return nil }
        let n = min(AudioExtractor.chunkBytes, leftover.count)
        let chunk = leftover.prefix(n)
        leftover.removeFirst(n)
        return Data(chunk)
    }

    /// One step of: read packet → send to decoder → drain frames → resample.
    /// Sets `fullyDrained = true` once the decoder reports EOF.
    private func pumpOnce() throws {
        guard let fmtCtx = formatContext, let codecCtx = codecContext,
              let pkt = packet, let frm = frame, let swrCtx = swrContext else {
            fullyDrained = true
            return
        }

        // Drain any frames currently available before reading more packets.
        while true {
            let r = avcodec_receive_frame(codecCtx, frm)
            if r == 0 {
                resampleFrame(frm, swr: swrCtx)
                continue
            }
            // EAGAIN = need more packets; AVERROR_EOF = decoder is done.
            if r == Self.AVERROR_EAGAIN {
                break
            }
            if r == Self.AVERROR_EOF {
                fullyDrained = true
                // Final swr drain (any padding samples).
                drainResampler(swr: swrCtx)
                return
            }
            throw TranscriptionError.unsupportedFormat(
                url: URL(fileURLWithPath: ""),
                detail: "avcodec_receive_frame: \(Self.ffmpegError(r))"
            )
        }

        if sentEOF {
            // We've already told the decoder there's no more input but it
            // didn't fully drain above; loop and let it.
            return
        }

        // Pull the next packet from the container; skip non-audio streams.
        let readRet = av_read_frame(fmtCtx, pkt)
        if readRet == Self.AVERROR_EOF {
            // Tell the decoder no more input is coming.
            _ = avcodec_send_packet(codecCtx, nil)
            sentEOF = true
            return
        }
        guard readRet >= 0 else {
            throw TranscriptionError.unsupportedFormat(
                url: URL(fileURLWithPath: ""),
                detail: "av_read_frame: \(Self.ffmpegError(readRet))"
            )
        }
        defer { av_packet_unref(pkt) }
        if pkt.pointee.stream_index != audioStreamIndex {
            return
        }
        let sendRet = avcodec_send_packet(codecCtx, pkt)
        if sendRet < 0 && sendRet != Self.AVERROR_EAGAIN {
            // Some malformed packets cause this; skip rather than abort.
            return
        }
    }

    /// Convert a decoded `AVFrame` into PCM16-LE mono @ 16 kHz and append
    /// to the leftover buffer.
    private func resampleFrame(_ frm: UnsafeMutablePointer<AVFrame>, swr: OpaquePointer) {
        let inSamples = frm.pointee.nb_samples
        // Headroom per swresample docs: out = (in * out_sr / in_sr) + 32.
        let outSampleRate = AudioExtractor.sampleRate
        let inSampleRate = max(Int32(1), Int32(frm.pointee.sample_rate))
        let outSamplesEstimate = Int32((Int64(inSamples) * Int64(outSampleRate) / Int64(inSampleRate)) + 32)
        let outBufBytes = Int(outSamplesEstimate) * 2  // S16 mono

        var outBuffer = [UInt8](repeating: 0, count: outBufBytes)
        let written = swrConvert(
            swr: swr,
            output: &outBuffer,
            outSamples: outSamplesEstimate,
            input: frm.pointee.extended_data,
            inSamples: inSamples
        )
        if written > 0 {
            leftover.append(contentsOf: outBuffer.prefix(Int(written) * 2))
        }
    }

    /// Drain any residual samples buffered inside libswresample after EOF.
    private func drainResampler(swr: OpaquePointer) {
        let outBufBytes = 32 * 2
        var outBuffer = [UInt8](repeating: 0, count: outBufBytes)
        let written = swrConvert(
            swr: swr,
            output: &outBuffer,
            outSamples: 32,
            input: nil,
            inSamples: 0
        )
        if written > 0 {
            leftover.append(contentsOf: outBuffer.prefix(Int(written) * 2))
        }
    }

    /// Tiny wrapper around `swr_convert` that handles the
    /// `uint8_t **` ↔ Swift pointer-to-pointer dance once.
    private func swrConvert(
        swr: OpaquePointer,
        output: inout [UInt8],
        outSamples: Int32,
        input: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        inSamples: Int32
    ) -> Int32 {
        return output.withUnsafeMutableBufferPointer { outBuf in
            var outBase: UnsafeMutablePointer<UInt8>? = outBuf.baseAddress
            return withUnsafeMutablePointer(to: &outBase) { outBasePP -> Int32 in
                let inPtrs: UnsafePointer<UnsafePointer<UInt8>?>?
                if let input {
                    inPtrs = unsafeBitCast(input, to: UnsafePointer<UnsafePointer<UInt8>?>?.self)
                } else {
                    inPtrs = nil
                }
                return swr_convert(swr, outBasePP, outSamples, inPtrs, inSamples)
            }
        }
    }

    // MARK: - FFmpeg constants & helpers

    /// Translate an FFmpeg negative-error-code into a readable string via
    /// `av_strerror`.
    private static func ffmpegError(_ code: Int32) -> String {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        defer { buf.deallocate() }
        if av_strerror(code, buf, 256) == 0 {
            return String(cString: buf) + " (\(code))"
        }
        return "unknown ffmpeg error \(code)"
    }

    /// `AVERROR(EAGAIN)` macro from libavutil/error.h. The C macro is not
    /// importable from Swift, so we recompute it.
    private static let AVERROR_EAGAIN: Int32 = -35  // EAGAIN on Darwin is 35.
    /// `AVERROR_EOF` is `FFERRTAG('E','O','F',' ')` = -('E' | 'O'<<8 | 'F'<<16 | ' '<<24).
    private static let AVERROR_EOF: Int32 = {
        let v: UInt32 = UInt32(UInt8(ascii: "E"))
              | (UInt32(UInt8(ascii: "O")) << 8)
              | (UInt32(UInt8(ascii: "F")) << 16)
              | (UInt32(UInt8(ascii: " ")) << 24)
        return -Int32(bitPattern: v)
    }()
}
