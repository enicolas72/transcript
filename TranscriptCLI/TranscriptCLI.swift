import Foundation
import ArgumentParser

@main
struct TranscriptCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Transcribe audio and video files with speaker detection.",
        discussion: """
            Transcribes one or more audio/video files using on-device Parakeet ASR \
            with optional WeSpeaker speaker detection. Outputs .txt and/or .srt files.

            On first run, models are downloaded automatically (~700 MB).
            """
    )

    @Argument(help: "Audio or video files to transcribe.")
    var files: [String]

    @Option(name: .shortAndLong, help: "Output directory (default: same as input file).")
    var output: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable speaker detection (default: on).")
    var speakers: Bool = true

    @Flag(name: .long, help: "Generate .txt transcript (default if no format specified).")
    var txt: Bool = false

    @Flag(name: .long, help: "Generate .srt subtitles.")
    var srt: Bool = false

    mutating func validate() throws {
        guard !files.isEmpty else {
            throw ValidationError("At least one input file is required.")
        }
        for file in files {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("File not found: \(file)")
            }
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

        let outputDir = output.map { URL(fileURLWithPath: $0) }
        let service = TranscriptionService()

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
                    speakerDetection: speakers
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
