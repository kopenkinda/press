import AppKit
import SwiftUI

// One windowless job. The app queues jobs so password and error prompts never
// compete. The model still inspects every archive before writing any files.
@MainActor
final class DirectExtraction: NSObject, NSWindowDelegate {
    let source: URL
    let model = ArchiveModel()
    private let completed: () -> Void
    private var prompt: NSPanel?
    private var progress: NSPanel?
    private var cancelled = false
    private var finished = false

    init(source: URL, completed: @escaping () -> Void) {
        self.source = source
        self.completed = completed
        super.init()
        model.onPasswordRequest = { [weak self] in self?.showPasswordPrompt() }
        model.onCompletion = { [weak self] error in self?.finish(error: error) }
    }

    func start() {
        model.open(source, behavior: .extractBeside)
        // Like Archive Utility, show progress only for jobs that take a moment.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.showProgress()
        }
    }

    func cancel() {
        cancelled = true
        closePrompt()
        closeProgress()
        model.cancel()
    }

    private func showProgress() {
        guard !finished, !cancelled, prompt == nil else { return }
        if let progress { progress.orderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Press"
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: ExtractionProgress(
            model: model, source: source, stop: { [weak self] in self?.cancel() }))
        progress = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeProgress() {
        progress?.delegate = nil
        progress?.close()
        progress = nil
    }

    private func showPasswordPrompt() {
        guard !cancelled else { model.submitPassword(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 388, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Extract \(source.lastPathComponent)"
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: PasswordPrompt(
            name: source.lastPathComponent, hint: model.passwordHint,
            submit: { [weak self] value in self?.submitPassword(value) }))
        prompt = panel
        progress?.orderOut(nil)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func submitPassword(_ value: String?) {
        closePrompt()
        model.submitPassword(value)
        if value != nil { showProgress() }
    }

    private func closePrompt() {
        prompt?.delegate = nil
        prompt?.close()
        prompt = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === progress { cancel() } else { submitPassword(nil) }
        return false
    }

    private func finish(error: String?) {
        finished = true
        closePrompt()
        closeProgress()
        if let error, !cancelled {
            let alert = NSAlert()
            alert.messageText = "Couldn't extract \(source.lastPathComponent)"
            alert.informativeText = error
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else if !cancelled, let output = model.output {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
        completed()
    }
}

struct ExtractionProgress: View {
    let model: ArchiveModel
    let source: URL
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: source.path))
                .resizable().frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Expanding “\(source.lastPathComponent)”")
                    .lineLimit(1).truncationMode(.middle)
                if let fraction = model.extractionProgress {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(action: stop) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop")
            .accessibilityLabel("Stop")
        }
        .padding(16)
        .frame(width: 420)
    }

    private var detail: String {
        guard model.phase == .extracting, let written = model.extractedBytes else { return "Reading archive…" }
        let done = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
        guard let total = model.preview?.expandedSize else { return done }
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}
