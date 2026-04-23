import Foundation
import ArgumentParser

@main
struct TranscriptCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Transcribe audio and video files via xAI Speech-to-Text.",
        discussion: """
            Sends each file to xAI's STT API (https://api.x.ai/v1/stt) and \
            writes .txt and/or .srt next to the input. Word-level timestamps \
            and speaker diarization are returned in a single API call.

            The API key is read (in order): --api-key flag, $XAI_API_KEY \
            environment variable, or the key saved by the GUI app.
            """
    )

    @Argument(help: "Audio or video files to transcribe.")
    var files: [String]

    @Option(name: .shortAndLong, help: "Output directory (default: same as input file).")
    var output: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable speaker detection (currently ignored — xAI diarize=true OOMs).")
    var speakers: Bool = false

    @Flag(name: .long, help: "Generate .txt transcript (default if no format specified).")
    var txt: Bool = false

    @Flag(name: .long, help: "Generate .srt subtitles.")
    var srt: Bool = false

    @Option(name: .shortAndLong, help: """
        Language: en, fr, de, es, it, pt, nl, ru, zh, ja, ko. Default: en.
        (xAI's streaming endpoint requires an explicit language — no auto.)
        """)
    var language: String = "en"

    @Option(name: .long, help: "xAI API key. Overrides $XAI_API_KEY and the GUI's saved key.")
    var apiKey: String?

    mutating func validate() throws {
        guard !files.isEmpty else {
            throw ValidationError("At least one input file is required.")
        }
        for file in files {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("File not found: \(file)")
            }
        }
        guard TranscriptLanguage(rawValue: language) != nil else {
            throw ValidationError("Unknown language code: \(language). Use one of: \(TranscriptLanguage.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if let dir = output {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    throw ValidationError("Output path is not a directory: \(dir)")
                }
            } else {
                do {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                } catch {
                    throw ValidationError("Cannot create output directory: \(dir)")
                }
            }
        }
    }

    func run() async throws {
        // Default to .txt if no format specified
        let txtEnabled = txt || !srt
        let srtEnabled = srt

        let lang = TranscriptLanguage(rawValue: language) ?? .english
        let outputDir = output.map { URL(fileURLWithPath: $0) }
        let service = TranscriptionService()

        let resolvedKey: String = {
            if let k = apiKey, !k.isEmpty { return k }
            if let k = ProcessInfo.processInfo.environment["XAI_API_KEY"], !k.isEmpty { return k }
            return UserDefaults.standard.string(forKey: "xAIApiKey") ?? ""
        }()

        if resolvedKey.isEmpty {
            log("Error: no xAI API key. Pass --api-key, set $XAI_API_KEY, or save one in the GUI app.")
            throw ExitCode.failure
        }

        if speakers {
            log("Note: --speakers is currently ignored (xAI diarize=true OOMs); proceeding without speaker detection.")
        }

        for (i, file) in files.enumerated() {
            let url = URL(fileURLWithPath: file)
            let name = url.lastPathComponent

            if files.count > 1 {
                log("[\(i + 1)/\(files.count)] \(name)")
            }

            do {
                let result = try await service.transcribe(
                    fileURL: url,
                    outputDir: outputDir,
                    txtEnabled: txtEnabled,
                    srtEnabled: srtEnabled,
                    speakerDetection: false,
                    language: lang,
                    apiKey: resolvedKey
                ) { update in
                    switch update.kind {
                    case .status(let text):
                        log(text)
                    case .log(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { log(trimmed) }
                    case .progress:
                        break // no progress bar in CLI
                    }
                }

                if let path = result.txtPath {
                    print(path)
                }
                if let path = result.srtPath {
                    print(path)
                }
            } catch {
                log("Error processing \(name): \(error.localizedDescription)")
                if files.count == 1 {
                    throw ExitCode.failure
                }
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
