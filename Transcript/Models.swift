import Foundation

enum FileStatus: Equatable {
    case waiting
    case processing
    case done(txtPath: String?, srtPath: String?)
    case error(String)

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .processing: return "Processing"
        case .done: return "Done"
        case .error: return "Error"
        }
    }

    /// Hover tooltip shown on the file-row status. Surfaces the full error
    /// message or the output paths without requiring the user to open the
    /// log panel.
    var tooltip: String {
        switch self {
        case .waiting: return "Waiting to be processed"
        case .processing: return "Processing…"
        case .done(let txtPath, let srtPath):
            var parts = ["Done"]
            if let p = txtPath { parts.append("TXT: \(p)") }
            if let p = srtPath { parts.append("SRT: \(p)") }
            return parts.joined(separator: "\n")
        case .error(let message): return message
        }
    }
}

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    var status: FileStatus = .waiting

    var fileName: String { url.lastPathComponent }
}

enum OutputFolder: Equatable {
    case sameAsInput
    case custom(URL)
}

/// Transcription language. Mapped 1:1 onto xAI's STT `language=` query
/// param. Auto-detection is not in this list — xAI's streaming endpoint
/// rejects the WebSocket handshake when no language is specified, and
/// does not accept `language=auto`.
enum TranscriptLanguage: String, CaseIterable, Identifiable, Equatable {
    case english = "en"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case russian = "ru"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .russian: return "Russian"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}

struct TranscriptionSettings {
    /// Key under which the output folder is persisted. Under App Sandbox a
    /// raw path is useless across launches, so we store a security-scoped
    /// bookmark instead.
    private static let outputFolderBookmarkKey = "outputFolderBookmark"

    var outputFolder: OutputFolder {
        didSet {
            switch outputFolder {
            case .sameAsInput:
                UserDefaults.standard.removeObject(forKey: Self.outputFolderBookmarkKey)
            case .custom(let url):
                // Security-scoped bookmark so the app can reach the folder
                // again on next launch under App Sandbox.
                if let data = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(data, forKey: Self.outputFolderBookmarkKey)
                }
            }
        }
    }
    var txtEnabled: Bool {
        didSet { UserDefaults.standard.set(txtEnabled, forKey: "txtEnabled") }
    }
    var speakerDetection: Bool {
        didSet { UserDefaults.standard.set(speakerDetection, forKey: "speakerDetection") }
    }
    var srtEnabled: Bool {
        didSet { UserDefaults.standard.set(srtEnabled, forKey: "srtEnabled") }
    }
    var language: TranscriptLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "xAIApiKey") }
    }

    init() {
        let d = UserDefaults.standard
        outputFolder = Self.resolveStoredOutputFolder()
        txtEnabled = d.object(forKey: "txtEnabled") as? Bool ?? true
        speakerDetection = d.object(forKey: "speakerDetection") as? Bool ?? true
        srtEnabled = d.object(forKey: "srtEnabled") as? Bool ?? true
        language = TranscriptLanguage(rawValue: d.string(forKey: "language") ?? "en") ?? .english
        apiKey = d.string(forKey: "xAIApiKey") ?? ""
    }

    /// Resolve the stored security-scoped bookmark, if any. `startAccessing…`
    /// is called and left active for the lifetime of the app — writes to the
    /// folder need the scope held.
    private static func resolveStoredOutputFolder() -> OutputFolder {
        guard let data = UserDefaults.standard.data(forKey: outputFolderBookmarkKey) else {
            return .sameAsInput
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            UserDefaults.standard.removeObject(forKey: outputFolderBookmarkKey)
            return .sameAsInput
        }
        _ = url.startAccessingSecurityScopedResource()
        return .custom(url)
    }
}

struct TranscriptionResult {
    let txtPath: String?
    let srtPath: String?
}

struct ProgressUpdate: Sendable {
    enum Kind: Sendable {
        case log(String)
        case progress(Double)
        case status(String)
    }
    let kind: Kind
}

struct LabeledSegment {
    let start: Double
    let end: Double
    let text: String
    /// Speaker label (e.g. "Speaker A") or an empty string when diarization
    /// was disabled.
    let speaker: String
}

enum TranscriptionError: LocalizedError {
    case noOutput
    case emptyTranscription
    /// The embedded FFmpeg build could not open or decode the file.
    /// `detail` carries the underlying error chain or a hint.
    case unsupportedFormat(url: URL, detail: String)
    /// macOS App Sandbox refused a write next to a dropped file. Files
    /// dropped on the app grant only read access to the file itself; the
    /// fix is to pick a custom output folder in Settings, which we receive
    /// via NSOpenPanel and persist as a security-scoped bookmark.
    case outputPermissionDenied(folder: String)

    var errorDescription: String? {
        switch self {
        case .noOutput:
            return "No audio track found. Check that the input is a valid audio/video file."
        case .emptyTranscription:
            return "Transcription produced no words. The file may contain no speech."
        case .unsupportedFormat(let url, let detail):
            return "Couldn't decode \"\(url.lastPathComponent)\": \(detail)"
        case .outputPermissionDenied(let folder):
            return """
                macOS sandbox blocked writing to \"\(folder)\". Files dropped onto the app \
                don't grant write access to their parent folder. \
                Pick a Custom output folder in the Settings sidebar (left), then retry.
                """
        }
    }
}
