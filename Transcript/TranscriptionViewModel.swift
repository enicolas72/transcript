import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var fileQueue: [FileItem] = []
    @Published var logOutput: String = ""
    @Published var statusText: String = ""
    @Published var progressFraction: Double? = nil
    @Published var settings = TranscriptionSettings()

    private let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "aac", "aiff", "caf",
        "mp4", "mov"
    ]

    private var currentTask: Task<Void, Never>?

    var isProcessing: Bool {
        fileQueue.contains { $0.status == .processing }
    }

    // MARK: - Drop Handling

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let typeID = UTType.fileURL.identifier
        let validProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(typeID) }
        guard !validProviders.isEmpty else { return false }

        for provider in validProviders {
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else { return }
                Task { @MainActor in
                    self?.addFile(url: url)
                }
            }
        }
        return true
    }

    // MARK: - Queue Management

    func addFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return }
        guard !fileQueue.contains(where: { $0.url == url && ($0.status == .waiting || $0.status == .processing) }) else { return }

        fileQueue.append(FileItem(url: url))
        processNextIfNeeded()
    }

    func removeFile(id: UUID) {
        guard let index = fileQueue.firstIndex(where: { $0.id == id }) else { return }
        let wasProcessing = fileQueue[index].status == .processing

        if wasProcessing {
            currentTask?.cancel()
            currentTask = nil
        }

        fileQueue.remove(at: index)

        if wasProcessing {
            logOutput = ""
            statusText = ""
            progressFraction = nil
            processNextIfNeeded()
        }
    }

    // MARK: - Processing

    private func processNextIfNeeded() {
        guard !isProcessing else { return }
        guard let index = fileQueue.firstIndex(where: { $0.status == .waiting }) else {
            progressFraction = nil
            return
        }
        startProcessing(at: index)
    }

    private func startProcessing(at index: Int) {
        guard settings.txtEnabled || settings.srtEnabled else {
            fileQueue[index].status = .error("No output formats enabled")
            processNextIfNeeded()
            return
        }

        fileQueue[index].status = .processing
        logOutput = ""
        statusText = "Starting \(fileQueue[index].fileName)..."
        progressFraction = nil

        let fileURL = fileQueue[index].url
        let fileId = fileQueue[index].id

        let outputDir: URL?
        switch settings.outputFolder {
        case .sameAsInput: outputDir = nil
        case .custom(let url): outputDir = url
        }

        let capturedSettings = settings

        currentTask = Task {
            do {
                let service = TranscriptionService()
                let result = try await service.transcribe(
                    fileURL: fileURL,
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

                if let idx = fileQueue.firstIndex(where: { $0.id == fileId }) {
                    fileQueue[idx].status = .done(txtPath: result.txtPath, srtPath: result.srtPath)
                }
                statusText = "Done"
                progressFraction = 1.0
            } catch is CancellationError {
                // File was removed during processing
            } catch {
                if let idx = fileQueue.firstIndex(where: { $0.id == fileId }) {
                    fileQueue[idx].status = .error(error.localizedDescription)
                }
                logOutput += "Error: \(error.localizedDescription)\n"
                statusText = "Error"
            }

            processNextIfNeeded()
        }
    }

    // MARK: - Settings

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
