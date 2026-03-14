import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var state: AppState = .idle
    @Published var logOutput: String = ""
    @Published var statusText: String = ""
    @Published var progressFraction: Double? = nil
    @Published var settings = TranscriptionSettings()

    let availableModels = ["tiny", "base", "small", "medium", "large"]

    private let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "ogg",
        "mp4", "mov", "mkv", "avi", "webm"
    ]

    private var currentTask: Task<Void, Never>?

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        let typeID = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeID) else { return false }

        provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else {
                Task { @MainActor in
                    self?.state = .error("Could not read dropped file URL.")
                }
                return
            }
            Task { @MainActor in
                self?.startTranscription(fileURL: url)
            }
        }
        return true
    }

    func startTranscription(fileURL: URL) {
        let ext = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            state = .error("Unsupported file type: .\(ext)\n\nSupported formats: mp3, wav, m4a, flac, ogg, mp4, mov, mkv, avi, webm")
            return
        }

        guard settings.txtEnabled || settings.srtEnabled else {
            state = .error("Enable at least one output format (.txt or .srt).")
            return
        }

        state = .processing
        logOutput = ""
        statusText = "Starting..."
        progressFraction = nil

        let outputDir: URL?
        switch settings.outputFolder {
        case .sameAsInput:
            outputDir = nil
        case .custom(let url):
            outputDir = url
        }

        let capturedSettings = settings

        currentTask = Task {
            do {
                let service = TranscriptionService()
                let result = try await service.transcribe(
                    fileURL: fileURL,
                    model: capturedSettings.model,
                    outputDir: outputDir,
                    txtEnabled: capturedSettings.txtEnabled,
                    srtEnabled: capturedSettings.srtEnabled,
                    speakerDetection: capturedSettings.speakerDetection
                ) { [weak self] update in
                    Task { @MainActor in
                        switch update.kind {
                        case .log(let text):
                            self?.logOutput += text + "\n"
                        case .progress(let fraction):
                            self?.progressFraction = fraction
                        case .status(let text):
                            self?.statusText = text
                        }
                    }
                }
                state = .done(txtPath: result.txtPath, srtPath: result.srtPath)
                statusText = "Done!"
                progressFraction = 1.0
            } catch {
                state = .error(error.localizedDescription)
                statusText = ""
            }
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        logOutput = ""
        statusText = ""
        progressFraction = nil
    }

    func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolder = .custom(url)
        }
    }
}
