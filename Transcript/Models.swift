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

/// Transcription language. Mapped 1:1 onto xAI's STT language hint (except
/// `.auto`, which omits the hint and lets the API auto-detect).
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
    case auto = "auto"

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
        case .auto: return "Automatic"
        }
    }
}

struct TranscriptionSettings {
    var outputFolder: OutputFolder {
        didSet {
            switch outputFolder {
            case .sameAsInput:
                UserDefaults.standard.removeObject(forKey: "outputFolder")
            case .custom(let url):
                UserDefaults.standard.set(url.path, forKey: "outputFolder")
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
        if let path = d.string(forKey: "outputFolder") {
            outputFolder = .custom(URL(fileURLWithPath: path))
        } else {
            outputFolder = .sameAsInput
        }
        txtEnabled = d.object(forKey: "txtEnabled") as? Bool ?? true
        speakerDetection = d.object(forKey: "speakerDetection") as? Bool ?? true
        srtEnabled = d.object(forKey: "srtEnabled") as? Bool ?? true
        language = TranscriptLanguage(rawValue: d.string(forKey: "language") ?? "en") ?? .english
        apiKey = d.string(forKey: "xAIApiKey") ?? ""
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

    var errorDescription: String? {
        switch self {
        case .noOutput:
            return "No audio track found. Check that the input is a valid audio/video file."
        case .emptyTranscription:
            return "Transcription produced no words. The file may contain no speech."
        }
    }
}
