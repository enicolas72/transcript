import SwiftUI
import UniformTypeIdentifiers

@main
struct TranscriptApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

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

struct ContentView: View {
    @StateObject private var vm = TranscriptionViewModel()
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            sidebarView
                .frame(width: 220)

            Divider()

            // Main content area
            VStack(spacing: 0) {
                switch vm.state {
                case .idle:
                    dropZone
                case .processing:
                    processingView
                case .done(let txtPath, let srtPath):
                    doneView(txtPath: txtPath, srtPath: srtPath)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 500)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard vm.state == .idle else { return false }
            return vm.handleDrop(providers: providers)
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            // Model
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: $vm.settings.model) {
                    ForEach(vm.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(vm.state == .processing)
            }

            Divider()

            // Output folder
            VStack(alignment: .leading, spacing: 6) {
                Text("Output folder")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Picker("", selection: Binding(
                    get: {
                        if case .sameAsInput = vm.settings.outputFolder { return 0 }
                        return 1
                    },
                    set: { val in
                        if val == 0 {
                            vm.settings.outputFolder = .sameAsInput
                        } else if case .custom = vm.settings.outputFolder {
                            // keep existing custom folder
                        } else {
                            vm.pickOutputFolder()
                        }
                    }
                )) {
                    Text("Same as input file").tag(0)
                    Text("Custom folder").tag(1)
                }
                .pickerStyle(.radioGroup)
                .disabled(vm.state == .processing)

                if case .custom(let url) = vm.settings.outputFolder {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.leading, 20)

                    Button("Change...") {
                        vm.pickOutputFolder()
                    }
                    .font(.caption)
                    .padding(.leading, 20)
                    .disabled(vm.state == .processing)
                }
            }

            Divider()

            // Output formats
            VStack(alignment: .leading, spacing: 6) {
                Text("Output formats")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Toggle(isOn: $vm.settings.txtEnabled) {
                    Text(".txt transcript")
                }
                .disabled(vm.state == .processing)

                if vm.settings.txtEnabled {
                    Toggle(isOn: $vm.settings.speakerDetection) {
                        Text("Speaker detection")
                    }
                    .padding(.leading, 20)
                    .disabled(vm.state == .processing)
                }

                Toggle(isOn: $vm.settings.srtEnabled) {
                    Text(".srt subtitles")
                }
                .disabled(vm.state == .processing)
            }

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Main Content

    private var dropZone: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            Text("Drop audio or video file here")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("mp3, wav, m4a, flac, ogg, mp4, mov, mkv, avi, webm")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.4))
                .padding(20)
        )
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            if let fraction = vm.progressFraction {
                ProgressView(value: fraction)
                    .padding(.horizontal)
                    .padding(.top, 20)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                    .padding(.top, 20)
            }

            Text(vm.statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.logOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                        .id("log")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .onChange(of: vm.logOutput) {
                    proxy.scrollTo("log", anchor: .bottom)
                }
            }

            Spacer()
        }
    }

    private func doneView(txtPath: String?, srtPath: String?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("Transcription Complete")
                .font(.title2)

            VStack(alignment: .leading, spacing: 8) {
                if let txtPath {
                    fileLink(path: txtPath, icon: "doc.text", label: "Text transcript")
                }
                if let srtPath {
                    fileLink(path: srtPath, icon: "captions.bubble", label: "SRT subtitles")
                }
            }
            .padding()

            Button("Transcribe Another") {
                vm.reset()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private func fileLink(path: String, icon: String, label: String) -> some View {
        Button {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } label: {
            HStack {
                Image(systemName: icon)
                VStack(alignment: .leading) {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("Error")
                .font(.title2)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if !vm.logOutput.isEmpty {
                ScrollView {
                    Text(vm.logOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }

            Button("Try Again") {
                vm.reset()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}
