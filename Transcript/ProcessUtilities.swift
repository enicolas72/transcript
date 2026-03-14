import Foundation

/// Buffers streamed data and emits complete lines via callback.
final class LineBuffer: @unchecked Sendable {
    private var buffer = ""
    private let onLine: (String) -> Void
    private let lock = NSLock()

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ str: String) {
        lock.lock()
        buffer += str
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            lock.unlock()
            onLine(line)
            lock.lock()
        }
        while let range = buffer.range(of: "\r") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            lock.unlock()
            if !line.isEmpty { onLine(line) }
            lock.lock()
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let remaining = buffer
        buffer = ""
        lock.unlock()
        if !remaining.isEmpty {
            onLine(remaining)
        }
    }
}

/// Collects log lines and progress, flushes to UI at a throttled interval.
final class ThrottledOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLines: [String] = []
    private var latestEndTime: Double?
    private let onFlush: ([String], Double?) -> Void
    private var timer: DispatchSourceTimer?

    init(interval: TimeInterval, onFlush: @escaping ([String], Double?) -> Void) {
        self.onFlush = onFlush

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.flush()
        }
        t.resume()
        self.timer = t
    }

    deinit {
        timer?.cancel()
    }

    func addLine(_ line: String) {
        lock.lock()
        pendingLines.append(line)
        lock.unlock()
    }

    func updateEndTime(_ time: Double) {
        lock.lock()
        latestEndTime = time
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let lines = pendingLines
        let endTime = latestEndTime
        pendingLines = []
        lock.unlock()

        if !lines.isEmpty || endTime != nil {
            onFlush(lines, endTime)
        }
    }

    func forceFlush() {
        timer?.cancel()
        timer = nil
        flush()
    }
}
