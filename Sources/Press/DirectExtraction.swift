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
    private var cancelled = false

    init(source: URL, completed: @escaping () -> Void) {
        self.source = source
        self.completed = completed
        super.init()
        model.onPasswordRequest = { [weak self] in self?.showPasswordPrompt() }
        model.onCompletion = { [weak self] error in self?.finish(error: error) }
    }

    func start() { model.open(source, behavior: .extractBeside) }

    func cancel() {
        cancelled = true
        closePrompt()
        model.cancel()
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
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func submitPassword(_ value: String?) {
        closePrompt()
        model.submitPassword(value)
    }

    private func closePrompt() {
        prompt?.delegate = nil
        prompt?.close()
        prompt = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        submitPassword(nil)
        return false
    }

    private func finish(error: String?) {
        closePrompt()
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
