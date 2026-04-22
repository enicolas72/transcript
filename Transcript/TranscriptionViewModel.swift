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

    func retryFile(id: UUID) {
        guard let index = fileQueue.firstIndex(where: { $0.id == id }),
              case .error = fileQueue[index].status else { return }
        fileQueue[index].status = .waiting
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
        guard !settings.apiKey.isEmpty else {
            fileQueue[index].status = .error("xAI API key is not set (see Settings).")
            processNextIfNeeded()
            return
        }

        // Check for existing output files before starting
        let fileURL = fileQueue[index].url
        let destDir: URL
        switch settings.outputFolder {
        case .sameAsInput: destDir = fileURL.deletingLastPathComponent()
        case .custom(let url): destDir = url
        }
        let baseName = fileURL.deletingPathExtension().lastPathComponent

        var existingFiles: [String] = []
        if settings.txtEnabled {
            let p = destDir.appendingPathComponent("\(baseName).txt")
            if FileManager.default.fileExists(atPath: p.path) { existingFiles.append(p.lastPathComponent) }
        }
        if settings.srtEnabled {
            let p = destDir.appendingPathComponent("\(baseName).srt")
            if FileManager.default.fileExists(atPath: p.path) { existingFiles.append(p.lastPathComponent) }
        }

        if !existingFiles.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Overwrite existing files?"
            alert.informativeText = existingFiles.joined(separator: ", ") + " already exist."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Skip")
            alert.alertStyle = .warning

            if alert.runModal() != .alertFirstButtonReturn {
                fileQueue[index].status = .error("Skipped (files exist)")
                processNextIfNeeded()
                return
            }
        }

        fileQueue[index].status = .processing
        logOutput = ""
        statusText = "Starting \(fileQueue[index].fileName)..."
        progressFraction = nil

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
                // NOTE: speakerDetection is pinned to false until xAI fixes
                // the diarize=true OOM. The Settings sidebar hides the
                // toggle; this guard also covers the stored-preference case.
                let result = try await service.transcribe(
                    fileURL: fileURL,
                    outputDir: outputDir,
                    txtEnabled: capturedSettings.txtEnabled,
                    srtEnabled: capturedSettings.srtEnabled,
                    speakerDetection: false,
                    language: capturedSettings.language,
                    apiKey: capturedSettings.apiKey
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
