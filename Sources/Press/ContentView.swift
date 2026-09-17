import SwiftUI

struct ContentView: View {
    @Bindable var model: ArchiveModel
    let dropArchives: ([URL]) -> Void
    var presentQuickLook: (URL?) -> Void = { _ in }
    let chooseArchives: () -> Void
    @State private var targeted = false
    @State private var selection: Set<ArchiveNode.ID> = []
    @AppStorage(OpenBehavior.dropDefaultsKey) private var dropBehavior = OpenBehavior.preview.rawValue

    var body: some View {
        VStack(spacing: 0) {
            if model.source == nil {
                emptyView
            } else if let preview = model.preview {
                HStack(spacing: 12) {
                    Text("\(preview.entries.count.formatted()) entries")
                    Spacer()
                    Text("\(size(preview.archiveSize)) archive")
                    Text(preview.expandedSize.map { "\(size($0)) expanded" } ?? "Expanded size unknown")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
                Divider()
                Table(preview.roots, children: \.children, selection: $selection) {
                    TableColumn("Name") { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            if entry.encrypted {
                                Image(systemName: "lock.fill")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .accessibilityLabel("Encrypted")
                            }
                        }
                        .help(entry.path)
                    }
                    TableColumn("Size") { entry in
                        Text(entry.isDirectory ? "" : entry.size.map(size) ?? "Unknown")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(90)
                }
                .onKeyPress(.space) {
                    guard !model.isBusy, let entry = selectedEntry else { return .ignored }
                    if model.quickLookURL != nil { model.dismissQuickLook() }
                    else { model.quickLook(entry.id) }
                    return .handled
                }
                .contextMenu(forSelectionType: ArchiveNode.ID.self) { ids in
                    Button("Quick Look") {
                        if let entry = selectedEntry(in: ids) {
                            selection = ids
                            model.quickLook(entry.id)
                        }
                    }
                    .disabled(model.isBusy || selectedEntry(in: ids) == nil)
                }
                .help("Select a file and press Space for Quick Look.")
                if preview.entries.isEmpty {
                    Text("This archive is empty.").foregroundStyle(.secondary).padding()
                }
            } else {
                VStack(spacing: 14) {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text("Reading archive…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "archivebox").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Preview unavailable").font(.headline)
                        Button("Reload Preview", action: model.reload)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.source != nil { footer }
        }
        .frame(minWidth: 560, minHeight: 360)
        .background(.background)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            dropArchives(files)
            return true
        } isTargeted: { targeted = $0 }
        .onChange(of: model.quickLookURL) { _, url in
            if url != nil, model.quickLookEntryID != selectedEntry?.id {
                model.dismissQuickLook()
            } else {
                presentQuickLook(url)
            }
        }
        .onChange(of: selection) { _, _ in
            if model.quickLookURL != nil, !model.isBusy {
                if let entry = selectedEntry { model.quickLook(entry.id) }
                else { model.dismissQuickLook() }
            }
        }
        .sheet(isPresented: $model.needsPassword) {
            PasswordPrompt(name: model.source?.lastPathComponent ?? "Archive", hint: model.passwordHint,
                           submit: model.submitPassword)
                .interactiveDismissDisabled()
        }
    }

    private var selectedEntry: ArchiveEntry? { selectedEntry(in: selection) }

    private func selectedEntry(in ids: Set<ArchiveNode.ID>) -> ArchiveEntry? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.preview?.entries.first { "file:\($0.id)" == id && !$0.isDirectory && !$0.isLink }
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 76, height: 76).accessibilityHidden(true)
            Text("Drop an archive here").font(.title3.weight(.medium))
            Text("\(openingDescription)\nRAR, ZIP, TAR, 7z, disk images, and more.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
            Button("Open Archives…", action: chooseArchives).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var openingDescription: String {
        switch OpenBehavior(rawValue: dropBehavior) ?? .preview {
        case .preview: "Look inside before extracting."
        case .extractBeside: "Extract into a new folder beside each archive."
        case .chooseDestination: "Choose where to extract each archive."
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = model.preview?.blockedReason {
                Label(reason, systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let output = model.output {
                HStack {
                    Label("Extracted to \(output.lastPathComponent)", systemImage: "checkmark.circle")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }
                .font(.callout)
                .help(output.path)
            }
            HStack {
                if model.isBusy {
                    if model.phase == .extracting || model.phase == .preparingPreview {
                        ProgressView().controlSize(.small)
                        Text(model.phase == .preparingPreview ? "Preparing Quick Look…" : "Extracting…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", action: model.cancel)
                } else {
                    Text("10 GB · 10,000 entries maximum")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open…", action: chooseArchives)
                    Button("Extract…", action: model.chooseDestination)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canExtract)
                }
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func size(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
