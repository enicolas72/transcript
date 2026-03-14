import SwiftUI

struct ContentView: View {
    @StateObject private var vm = TranscriptionViewModel()
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(vm: vm)
                .frame(width: 220)

            Divider()

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

    // MARK: - Drop Zone

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

    // MARK: - Processing

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

    // MARK: - Done

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

    // MARK: - Error

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
