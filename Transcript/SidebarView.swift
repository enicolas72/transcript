import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: TranscriptionViewModel
    @State private var showAcknowledgements = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            outputFolderSection
            Divider()
            languageSection
            Divider()
            outputFormatsSection
            Divider()
            apiKeySection

            Spacer()

            Button("Acknowledgements…") { showAcknowledgements = true }
                .font(.caption)
                .buttonStyle(.link)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsView(isPresented: $showAcknowledgements)
        }
    }

    // MARK: - Output Folder

    private var outputFolderSection: some View {
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
            .disabled(vm.isProcessing)

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
                .disabled(vm.isProcessing)
            }
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Language")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("", selection: $vm.settings.language) {
                ForEach(TranscriptLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(vm.isProcessing)
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("xAI API key")
                .font(.subheadline)
                .foregroundColor(.secondary)

            SecureField("xai-…", text: $vm.settings.apiKey)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isProcessing)

            if vm.settings.apiKey.isEmpty {
                Text("Required. Get one at console.x.ai.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Output Formats

    private var outputFormatsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output formats")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Toggle(isOn: $vm.settings.txtEnabled) {
                Text(".txt transcript")
            }
            .disabled(vm.isProcessing)

            // Speaker detection toggle is temporarily hidden: xAI's STT API
            // OOMs on diarize=true for multi-minute inputs (reported upstream).
            // The underlying setting is still persisted so the UI can be
            // restored by un-commenting the Toggle below once xAI ships a fix.
            //
            // if vm.settings.txtEnabled {
            //     Toggle(isOn: $vm.settings.speakerDetection) {
            //         Text("Speaker detection")
            //     }
            //     .padding(.leading, 20)
            //     .disabled(vm.isProcessing)
            // }

            Toggle(isOn: $vm.settings.srtEnabled) {
                Text(".srt subtitles")
            }
            .disabled(vm.isProcessing)
        }
    }
}

// MARK: - Acknowledgements

private struct AcknowledgementsView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Open-source acknowledgements").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(loadLicenses())
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
        .frame(width: 640, height: 480)
    }

    private func loadLicenses() -> String {
        if let url = Bundle.main.url(forResource: "LICENSES", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "Acknowledgements file missing from bundle. See README on GitHub."
    }
}
