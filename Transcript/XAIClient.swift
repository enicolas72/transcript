import Foundation

/// Streaming client for xAI's Speech-to-Text WebSocket
/// (`wss://api.x.ai/v1/stt`). Pipes PCM chunks from an `AudioExtractor.PCMReader`
/// over the socket and decodes `transcript.partial` / `transcript.done` events
/// as they arrive. Replaces the earlier batch POST, which couldn't handle
/// long files inside the API's request timeout.
enum XAIClient {

    static let endpoint = URL(string: "wss://api.x.ai/v1/stt")!

    /// How many audio-seconds we push per wall-clock second. 1.0 = real-time.
    /// Set to `.infinity` to disable pacing entirely and stream as fast as
    /// the wire will carry; finite values target a pace using a
    /// self-correcting wall-clock budget in `sendPCM`.
    static let pacingRealtimeMultiplier: Double = .infinity

    /// Debug override: when true, the client requests `diarize=true`
    /// regardless of the `diarize` argument. xAI support has confirmed
    /// (2026-04-22) that streaming diarization is an acknowledged current
    /// limitation. Keep this at false; flip to true only to re-probe once
    /// xAI ships a fix.
    static let forceDiarize: Bool = false

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // WebSocket-level pings handle idle; we keep these generous for
        // very long uploads.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 4 * 3600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    struct Word: Decodable {
        let text: String
        let start: Double
        let end: Double
        let speaker: Int?
    }

    /// One chunk-final `transcript.partial` event, preserved as a natural
    /// cue boundary. SRT maps one-to-one onto these, and the TXT formatter
    /// uses them as paragraph separators.
    struct Segment {
        let start: Double
        let end: Double
        let text: String
        let words: [Word]
    }

    struct Response {
        let text: String
        let duration: Double?
        let words: [Word]
        let segments: [Segment]
    }

    /// Stream the audio over the WebSocket and return the final transcript.
    ///
    /// - `onFinalPartial` is fired for `transcript.partial` events with
    ///   `is_final = true` (i.e. chunk-final results, ~every 3 s of speech).
    ///   Fine for live display; the caller should NOT try to use these as
    ///   the authoritative transcript — the full one arrives in `transcript.done`.
    /// - `onUploadProgress(sent, total)` is called as PCM bytes are pushed.
    static func streamingTranscribe(
        reader: AudioExtractor.PCMReader,
        languageCode: String?,
        diarize: Bool,
        apiKey: String,
        log: @escaping @Sendable (String) -> Void,
        onFinalPartial: @escaping @Sendable (String) -> Void,
        onUploadProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Response {

        let url = makeWSURL(languageCode: languageCode, diarize: diarize)
        log("xAI: connecting to \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        task.resume()

        // Make sure the WebSocket is torn down on any exit path.
        @Sendable func teardown() { task.cancel(with: .normalClosure, reason: nil) }
        defer { teardown() }

        // Step 1: wait for transcript.created. A handshake failure shows
        // up here as NSURLError -1011 (badServerResponse) with no response
        // body accessible from URLSessionWebSocketTask. Re-wrap it with
        // actionable hints so the user isn't staring at
        // "There was a bad response from the server."
        let created: Event
        do {
            created = try await receiveEvent(task)
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorBadServerResponse {
            log("xAI: WebSocket handshake rejected by server (NSURLError -1011).")
            throw XAIError.protocolError("""
                xAI rejected the WebSocket handshake. Common causes: invalid API key, \
                unsupported parameter combination (e.g. missing language), or a server-side \
                outage. Check your API key in Settings, and try selecting a specific language \
                instead of Automatic.
                """)
        }
        guard created.type == "transcript.created" else {
            throw XAIError.protocolError("Expected transcript.created, got \(created.type)")
        }
        let audioSeconds = Double(reader.totalBytes) / Double(AudioExtractor.bytesPerSecond)
        if pacingRealtimeMultiplier.isFinite {
            let streamSeconds = audioSeconds / pacingRealtimeMultiplier
            log(String(format: "xAI: server ready, streaming PCM (%@ — %.1fx real-time, ~%.1f min wall)",
                       byteSize(reader.totalBytes),
                       pacingRealtimeMultiplier,
                       streamSeconds / 60))
        } else {
            log("xAI: server ready, streaming PCM (\(byteSize(reader.totalBytes)) — unpaced, as fast as the wire)")
        }

        // Step 2: run sender + receiver concurrently.
        let final: Response = try await withThrowingTaskGroup(of: GroupResult.self) { group in
            group.addTask {
                try await sendPCM(
                    reader: reader, task: task,
                    log: log, onUploadProgress: onUploadProgress
                )
                return .senderDone
            }
            group.addTask {
                let resp = try await receiveUntilDone(
                    task: task, log: log, onFinalPartial: onFinalPartial
                )
                return .response(resp)
            }

            var response: Response?
            for try await r in group {
                switch r {
                case .senderDone: continue
                case .response(let resp):
                    response = resp
                    group.cancelAll()
                }
            }
            guard let resp = response else {
                throw XAIError.protocolError("WebSocket closed before transcript.done")
            }
            return resp
        }

        return final
    }

    // MARK: - URL construction

    private static func makeWSURL(languageCode: String?, diarize: Bool) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "sample_rate", value: "\(AudioExtractor.sampleRate)"),
            .init(name: "encoding", value: "pcm"),
            .init(name: "interim_results", value: "false"),
        ]
        if let code = languageCode { items.append(.init(name: "language", value: code)) }
        if diarize || forceDiarize { items.append(.init(name: "diarize", value: "true")) }
        components.queryItems = items
        return components.url!
    }

    // MARK: - Sender

    private static func sendPCM(
        reader: AudioExtractor.PCMReader,
        task: URLSessionWebSocketTask,
        log: @escaping @Sendable (String) -> Void,
        onUploadProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        var sent: Int64 = 0
        let total = reader.totalBytes
        let start = DispatchTime.now()
        let bytesPerSec = Double(AudioExtractor.bytesPerSecond)

        while true {
            try Task.checkCancellation()
            guard let chunk = try reader.next() else { break }
            try await task.send(.data(chunk))
            sent += Int64(chunk.count)
            onUploadProgress(sent, total)

            // Self-correcting pace (skipped entirely when multiplier is
            // infinite, i.e. unpaced). Target wall time for everything sent
            // so far is (audio_seconds_sent / multiplier). If we're ahead of
            // that, sleep for the diff; if we're behind, don't sleep.
            if pacingRealtimeMultiplier.isFinite {
                let audioSecondsSent = Double(sent) / bytesPerSec
                let targetWallSeconds = audioSecondsSent / pacingRealtimeMultiplier
                let actualWallSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
                let sleepFor = targetWallSeconds - actualWallSeconds
                if sleepFor > 0 {
                    try await Task.sleep(nanoseconds: UInt64(sleepFor * 1_000_000_000))
                }
            }
        }

        // Signal end-of-stream so the server knows to emit transcript.done.
        try await task.send(.string(#"{"type":"audio.done"}"#))
        log("xAI: audio.done sent (\(byteSize(sent)) total)")
    }

    // MARK: - Receiver

    private static func receiveUntilDone(
        task: URLSessionWebSocketTask,
        log: @escaping @Sendable (String) -> Void,
        onFinalPartial: @escaping @Sendable (String) -> Void
    ) async throws -> Response {
        // `transcript.done` arrives with empty `words`/`text` in practice
        // (the xAI streaming service sends the authoritative transcript
        // piece-by-piece through `transcript.partial` events with
        // `is_final=true` and doesn't repeat them at the end). We
        // accumulate those chunk-finals here and use them as the canonical
        // final transcript, preferring the server's `transcript.done`
        // payload only if it is non-empty.
        var segments: [Segment] = []
        var accumulatedWords: [Word] = []

        while true {
            try Task.checkCancellation()
            let event = try await receiveEvent(task)
            switch event.type {
            case "transcript.partial":
                if event.is_final == true {
                    let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let words = event.words ?? []
                    let start = event.start ?? words.first?.start ?? 0
                    let end = (event.duration.map { start + $0 }) ?? words.last?.end ?? start
                    if !text.isEmpty || !words.isEmpty {
                        segments.append(Segment(start: start, end: end, text: text, words: words))
                        accumulatedWords.append(contentsOf: words)
                        if !text.isEmpty { onFinalPartial(text) }
                    }
                }
            case "transcript.done":
                let doneWords = event.words ?? []
                let doneText = event.text ?? ""
                let finalWords = !doneWords.isEmpty ? doneWords : accumulatedWords
                let finalText = !doneText.isEmpty ? doneText : segments.map(\.text).joined(separator: " ")
                log("xAI: transcript.done received (done.words=\(doneWords.count), \(segments.count) segments, \(accumulatedWords.count) accumulated words)")
                return Response(
                    text: finalText,
                    duration: event.duration,
                    words: finalWords,
                    segments: segments
                )
            case "error":
                throw XAIError.protocolError(event.message ?? "unknown error")
            case "transcript.created":
                continue  // shouldn't arrive a second time, but ignore if it does
            default:
                log("xAI: ignoring unknown event type \"\(event.type)\"")
            }
        }
    }

    private static func receiveEvent(_ task: URLSessionWebSocketTask) async throws -> Event {
        while true {
            let msg = try await task.receive()
            switch msg {
            case .string(let s):
                return try decodeEvent(from: Data(s.utf8))
            case .data(let d):
                return try decodeEvent(from: d)
            @unknown default:
                continue
            }
        }
    }

    private static func decodeEvent(from data: Data) throws -> Event {
        do {
            return try JSONDecoder().decode(Event.self, from: data)
        } catch {
            let preview = String(data: data.prefix(256), encoding: .utf8) ?? "<non-utf8>"
            throw XAIError.decodeFailed(underlying: error, preview: preview)
        }
    }

    // MARK: - Event schema

    private struct Event: Decodable {
        let type: String
        let text: String?
        let words: [Word]?
        let is_final: Bool?
        let speech_final: Bool?
        let start: Double?
        let duration: Double?
        let message: String?
    }

    private enum GroupResult {
        case senderDone
        case response(Response)
    }

    private static func byteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

enum XAIError: LocalizedError {
    case protocolError(String)
    case decodeFailed(underlying: Error, preview: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .protocolError(let msg):
            return "xAI STT stream error: \(msg)"
        case .decodeFailed(_, let preview):
            return "Could not parse xAI event. First bytes: \(preview)"
        case .missingAPIKey:
            return "xAI API key is not set. Paste it in the Settings sidebar (or pass --api-key / set XAI_API_KEY for the CLI)."
        }
    }
}
