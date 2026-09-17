import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Shared by the settings picker and all archive-opening entry points.
enum OpenBehavior: String, CaseIterable, Identifiable {
    case preview, extractBeside, chooseDestination
    static let defaultsKey = "openBehavior"
    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .preview
    }
    var id: Self { self }
    var label: String {
        switch self {
        case .preview: "Preview in Press"
        case .extractBeside: "Extract Beside the Archive"
        case .chooseDestination: "Choose Where to Extract"
        }
    }
}

@MainActor
final class SettingsWindow: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (title, symbol, view) in [
            ("General", "gearshape", AnyView(GeneralSettings())),
            ("File Types", "doc.on.doc", AnyView(FileTypeSettings()))
        ] {
            let host = NSHostingController(rootView: view)
            host.preferredContentSize = NSSize(width: 500, height: title == "General" ? 280 : 440)
            let tab = NSTabViewItem(viewController: host)
            tab.label = title
            tab.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(tab)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Press Settings"
        window.tabbingMode = .disallowed
        window.contentViewController = tabs
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.toolbar?.displayMode = .iconAndLabel
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("SettingsWindow is created in code.") }
}

private struct GeneralSettings: View {
    @AppStorage(OpenBehavior.defaultsKey) private var behavior = OpenBehavior.preview.rawValue

    var body: some View {
        Form {
            Picker("When opening an archive:", selection: $behavior) {
                ForEach(OpenBehavior.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            Text("Applies to Finder, Open, and drag and drop.")
                .font(.callout).foregroundStyle(.secondary)
            if behavior != OpenBehavior.preview.rawValue {
                Text("Extracts into a new folder named after the archive. Size and entry limits still apply.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 280)
    }
}

private struct FileTypeSettings: View {
    @State private var search = ""
    @State private var defaults: [String: URL] = [:]
    @State private var changing: String?
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("Find a format or extension", text: $search)
                .textFieldStyle(.roundedBorder).padding([.horizontal, .top], 20)
            Form {
                Section {
                    ForEach(visibleExtensions, id: \.self) { ext in
                        HStack(spacing: 12) {
                            Text(ext == "7z" ? "7z" : ext.uppercased())
                                .fontWeight(.medium).frame(width: 68, alignment: .leading)
                            if let app = defaults[ext] {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                    .resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                                Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
                                    .lineLimit(1).truncationMode(.middle)
                            } else {
                                Text("No default app").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if changing == ext {
                                ProgressView().controlSize(.small)
                            } else if isPress(defaults[ext]) {
                                Text("Default").foregroundStyle(.secondary)
                            } else {
                                Button("Use Press") { usePress(for: ext) }
                                    .disabled(changing != nil)
                                    .accessibilityLabel("Use Press for \(ext) archives")
                            }
                        }
                    }
                } header: {
                    Text("Default apps")
                } footer: {
                    Text("Choose which files open with Press in Finder. Extensions sharing a macOS file type change together.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 440)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert("Couldn't change the default app", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    private var visibleExtensions: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return ArchiveFormats.extensions }
        let matching = ArchiveFormats.all.filter {
            $0.name.lowercased().contains(query) || $0.extensions.contains { $0.contains(query) }
        }
        return Array(Set(matching.flatMap(\.extensions))).sorted()
    }

    private func isPress(_ url: URL?) -> Bool {
        guard let url else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func refresh() {
        defaults = Dictionary(uniqueKeysWithValues: ArchiveFormats.extensions.compactMap { ext in
            guard let type = UTType(filenameExtension: ext),
                  let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
            return (ext, app)
        })
    }

    private func usePress(for ext: String) {
        guard changing == nil, let type = UTType(filenameExtension: ext) else { return }
        changing = ext
        Task { @MainActor in
            defer { changing = nil; refresh() }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                refresh()
                if !isPress(defaults[ext]) {
                    errorMessage = "macOS didn't change the default app for \(ext.uppercased()) files. You can try again or use Finder's Get Info window."
                    showError = true
                }
            } catch {
                if (error as NSError).code != NSUserCancelledError {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}
