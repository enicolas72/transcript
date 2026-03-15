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
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
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
        model = d.string(forKey: "model") ?? "medium"
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

struct WhisperSegment: Decodable {
    let start: Double
    let end: Double
    let text: String
}

struct WhisperOutput: Decodable {
    let segments: [WhisperSegment]
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

struct DiarizationSegment {
    let start: Double       // seconds
    let end: Double         // seconds
    let speakerId: Int      // cluster index
    let speakerLabel: String // "Speaker A", "Speaker B", etc.
}

enum TranscriptionError: LocalizedError {
    case noOutput
    case emptyTranscription
    case whisperFailed(exitCode: Int32)
    case modelDownloadFailed(model: String)
    case diarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noOutput:
            return "Whisper did not produce an output file. Check that the input is a valid audio/video file."
        case .emptyTranscription:
            return "Transcription produced no segments. The file may contain no speech."
        case .whisperFailed(let code):
            return "Whisper exited with code \(code). Check the log output for details."
        case .modelDownloadFailed(let model):
            return "Failed to download the '\(model)' model. Check your internet connection and try again."
        case .diarizationFailed(let reason):
            return "Speaker detection failed: \(reason)"
        }
    }
}
