import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: TranscriptionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            modelSection
            Divider()
            outputFolderSection
            Divider()
            outputFormatsSection

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Model

    private var modelSection: some View {
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
    }
}
