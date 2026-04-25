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
        // AVFoundation native:
        "mp3", "wav", "m4a", "flac", "aac", "aiff", "caf",
        "mp4", "mov", "m4v", "ts",
        // FFmpeg fallback:
        "mkv", "webm", "ogg", "opus", "oga", "avi", "wmv", "wma", "asf",
    ]

    private var currentTask: Task<Void, Never>?

    /// Folders for which the user has granted write access, mapped from
    /// the destination we asked about to the URL the user selected
    /// (typically the same). Holding the URL keeps the sandbox extension
    /// alive. Persisted as security-scoped bookmarks under
    /// `folderAccessBookmarks` in UserDefaults — re-resolved at init so
    /// grants survive app quits.
    private var folderAccessGrants: [URL: URL] = [:]
    private static let folderAccessBookmarksKey = "folderAccessBookmarks"

    /// Free-tier per-file duration cap. 5 minutes.
    static let freeLimitSeconds: Double = 5 * 60

    /// Owned by `ContentView` and read here for the 5-minute Free gate.
    private let subscription: SubscriptionManager

    init(subscription: SubscriptionManager) {
        self.subscription = subscription
        loadFolderAccessBookmarks()
    }

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
        // Pre-check errors: surface them in the log panel *and* the file
        // row, so the user isn't staring at a bare "Error" badge with no
        // clue what went wrong.
        func fail(_ message: String) {
            fileQueue[index].status = .error(message)
            logOutput = "Error: \(message)\n"
            statusText = "Error"
            progressFraction = nil
            processNextIfNeeded()
        }

        guard settings.txtEnabled || settings.srtEnabled else {
            fail("No output formats enabled. Turn on .txt or .srt in the Settings sidebar.")
            return
        }
        guard !settings.apiKey.isEmpty else {
            fail("xAI API key is not set. Paste your key in the Settings sidebar on the left (get one at console.x.ai).")
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
        // Capture the Pro state at the moment the task starts. If the user
        // upgrades mid-queue, queued files retake the gate via the retry
        // button (the next click reads `isPro` again).
        let capturedMaxDuration: Double? = subscription.isPro ? nil : Self.freeLimitSeconds

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
                    apiKey: capturedSettings.apiKey,
                    maxDurationSeconds: capturedMaxDuration,
                    requestWriteAccess: { [weak self] folder in
                        guard let self else { return false }
                        return await self.requestWriteAccess(for: folder)
                    }
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

    /// Pop the system's "permission grant" UI for `folder`. Under App
    /// Sandbox, NSOpenPanel pre-pointed at a directory IS the system's
    /// permission gateway — there is no iOS-style yes/no popup for
    /// arbitrary folders. The user clicks Allow and the sandbox extends
    /// for that folder. We cache the granted URL in memory and persist
    /// a security-scoped bookmark so the grant survives app restarts.
    func requestWriteAccess(for folder: URL) async -> Bool {
        if folderAccessGrants[folder] != nil { return true }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.title = "Allow folder access"
        panel.prompt = "Allow"
        panel.message = """
            xTranscript needs your permission to save the .txt / .srt outputs in
            \"\(folder.lastPathComponent)\". Click Allow to grant access — \
            this is remembered across launches.
            """

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        folderAccessGrants[folder] = url
        persistGrant(folder: folder, url: url)
        return true
    }

    // MARK: - Bookmark persistence

    private func loadFolderAccessBookmarks() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.folderAccessBookmarksKey) as? [String: Data] else {
            return
        }
        var loaded: [URL: URL] = [:]
        var stillValid: [String: Data] = [:]
        for (path, bookmarkData) in raw {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale else {
                continue  // drop stale / unresolvable bookmarks
            }
            // Bookmark-resolved URLs require startAccessing to extend the
            // sandbox; URLs returned directly from NSOpenPanel don't.
            guard url.startAccessingSecurityScopedResource() else { continue }
            loaded[URL(fileURLWithPath: path)] = url
            stillValid[path] = bookmarkData
        }
        folderAccessGrants = loaded
        if stillValid.count != raw.count {
            UserDefaults.standard.set(stillValid, forKey: Self.folderAccessBookmarksKey)
        }
    }

    private func persistGrant(folder: URL, url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: Self.folderAccessBookmarksKey) as? [String: Data]) ?? [:]
        dict[folder.path] = bookmark
        UserDefaults.standard.set(dict, forKey: Self.folderAccessBookmarksKey)
    }
}
