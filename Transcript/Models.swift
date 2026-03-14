import Foundation

enum AppState: Equatable {
    case idle
    case processing
    case done(txtPath: String?, srtPath: String?)
    case error(String)
}

enum OutputFolder: Equatable {
    case sameAsInput
    case custom(URL)
}

struct TranscriptionSettings {
    var model: String = "medium"
    var outputFolder: OutputFolder = .sameAsInput
    var txtEnabled: Bool = true
    var speakerDetection: Bool = true
    var srtEnabled: Bool = true
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

enum TranscriptionError: LocalizedError {
    case noOutput
    case emptyTranscription
    case whisperFailed(exitCode: Int32)
    case modelDownloadFailed(model: String)

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
        }
    }
}
