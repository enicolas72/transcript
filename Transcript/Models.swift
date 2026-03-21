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
    let speaker: String
}

/// Lightweight timed word — our own type so that all speaker detection logic
/// can be tested without importing FluidAudio. TokenTiming is converted to
/// TimedWord at the boundary (in TranscriptMerger.merge).
struct TimedWord {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptionError: LocalizedError {
    case noOutput
    case emptyTranscription
    case modelDownloadFailed(String)
    case diarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noOutput:
            return "No audio track found. Check that the input is a valid audio/video file."
        case .emptyTranscription:
            return "Transcription produced no words. The file may contain no speech."
        case .modelDownloadFailed(let reason):
            return "Failed to download model: \(reason). Check your internet connection."
        case .diarizationFailed(let reason):
            return "Speaker detection failed: \(reason)"
        }
    }
}
