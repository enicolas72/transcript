import SwiftUI

struct ContentView: View {
    @StateObject private var subscription: SubscriptionManager
    @StateObject private var vm: TranscriptionViewModel
    @State private var isTargeted = false
    @State private var showUpgrade = false

    init() {
        // SwiftUI requires the StateObject's wrapped value to be set
        // synchronously here so that the ViewModel can hold a strong
        // reference to the same SubscriptionManager instance the sidebar
        // observes. Both are owned by ContentView for the window's lifetime.
        let subs = SubscriptionManager()
        _subscription = StateObject(wrappedValue: subs)
        _vm = StateObject(wrappedValue: TranscriptionViewModel(subscription: subs))
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(vm: vm, subscription: subscription)
                .frame(width: 220)

            Divider()

            centerPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            fileQueuePanel
                .frame(width: 240)
        }
        .frame(width: 900, height: 500)
        .background(WindowAccessor())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            vm.handleDrop(providers: providers)
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeView(isPresented: $showUpgrade, subscription: subscription)
        }
    }

    // MARK: - Center Panel

    @ViewBuilder
    private var centerPanel: some View {
        if vm.fileQueue.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("Drop files in the right panel to begin")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            VStack(spacing: 12) {
                if vm.isProcessing {
                    if let fraction = vm.progressFraction {
                        ProgressView(value: fraction)
                            .padding(.horizontal)
                            .padding(.top, 20)
                    } else {
                        ProgressView()
                            .scaleEffect(1.2)
                            .padding(.top, 20)
                    }
                }

                if !vm.statusText.isEmpty {
                    Text(vm.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)
                }

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
    }

    // MARK: - File Queue Panel

    private var fileQueuePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(vm.fileQueue.isEmpty ? "Files" : "Files (\(vm.fileQueue.count))")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            if vm.fileQueue.isEmpty {
                dropZone
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.fileQueue) { file in
                            fileRow(file)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            Text("Drop audio or video files here")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("mp3, m4a, mp4, mov, wav, flac, aac, aiff, caf\nmkv, webm, ogg/opus, avi, wmv, wma")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.3))
                .padding(12)
        )
    }

    // MARK: - File Row

    private func fileRow(_ file: FileItem) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if file.status == .processing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    }
                    Text(file.status.label)
                        .font(.caption)
                        .foregroundColor(statusColor(for: file.status))
                        .help(file.status.tooltip)
                }
            }

            Spacer()

            if file.status.suggestsUpgrade {
                Button {
                    showUpgrade = true
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Upgrade to xTranscript Pro")
            }

            if case .error = file.status {
                Button {
                    vm.retryFile(id: file.id)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Retry")
            }

            Button {
                vm.removeFile(id: file.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusColor(for status: FileStatus) -> Color {
        switch status {
        case .waiting: return .secondary
        case .processing: return .blue
        case .done: return .green
        case .error: return .red
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.setFrameAutosaveName("MainWindow")
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
