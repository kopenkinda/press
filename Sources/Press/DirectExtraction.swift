import AppKit
import Observation
import SwiftUI

// Windowless extraction. Up to five archives expand at once and share one
// progress panel with a row per archive. Password prompts still come one at a
// time, and each model still inspects its archive before writing any files.
@MainActor
final class DirectExtractions: NSObject, NSWindowDelegate {
    static let concurrencyLimit = 5

    private let list = ExtractionList()
    private let idle: () -> Void
    private var pending: [URL] = []
    private var active: [DirectExtraction] = []
    private var passwordRequests: [DirectExtraction] = []
    private var prompt: NSPanel?
    private var promptJob: DirectExtraction?
    private var progress: NSPanel?
    // Results are reported once the whole batch ends, so parallel jobs don't
    // open a Finder window or alert apiece.
    private var outputs: [URL] = []
    private var failures: [(source: URL, error: String)] = []
    var terminating = false

    init(idle: @escaping () -> Void) {
        self.idle = idle
        super.init()
    }

    var isIdle: Bool { active.isEmpty && pending.isEmpty }
    var models: [ArchiveModel] { active.map(\.model) }

    func add(_ urls: [URL]) {
        for url in urls {
            let url = url.standardizedFileURL
            if !active.contains(where: { $0.source == url }) && !pending.contains(url) {
                pending.append(url)
            }
        }
        startJobs()
        if isIdle { idle() }
    }

    func cancelAll() {
        pending.removeAll()
        for job in active { cancel(job) }
    }

    private func startJobs() {
        while !terminating, active.count < Self.concurrencyLimit, !pending.isEmpty {
            let job = DirectExtraction(source: pending.removeFirst())
            active.append(job)
            job.model.onPasswordRequest = { [weak self, weak job] in
                if let self, let job { self.requestPassword(for: job) }
            }
            job.model.onCompletion = { [weak self, weak job] error in
                if let self, let job { self.finish(job, error: error) }
            }
            job.model.open(job.source, behavior: .extractBeside)
            // Like Archive Utility, show progress only for jobs that take a moment.
            Task { [weak self, weak job] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let job, !job.cancelled, self.active.contains(where: { $0 === job }) else { return }
                self.list.jobs.append(job)
                self.showProgress()
            }
        }
    }

    private func cancel(_ job: DirectExtraction) {
        job.cancelled = true
        list.jobs.removeAll { $0 === job }
        if list.jobs.isEmpty { closeProgress() }
        passwordRequests.removeAll { $0 === job }
        if promptJob === job {
            closePrompt()
            showNextPrompt()
        }
        job.model.cancel()
    }

    private func finish(_ job: DirectExtraction, error: String?) {
        active.removeAll { $0 === job }
        list.jobs.removeAll { $0 === job }
        passwordRequests.removeAll { $0 === job }
        if promptJob === job {
            closePrompt()
            showNextPrompt()
        }
        if !job.cancelled {
            if let error { failures.append((job.source, error)) }
            else if let output = job.model.output { outputs.append(output) }
        }
        startJobs()
        if list.jobs.isEmpty { closeProgress() }
        guard isIdle else { return }
        reportResults()
        idle()
    }

    private func reportResults() {
        let outputs = outputs, failures = failures
        self.outputs.removeAll()
        self.failures.removeAll()
        guard !terminating else { return }
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        if let failure = failures.first, failures.count == 1 {
            alert.messageText = "Couldn't extract \(failure.source.lastPathComponent)"
            alert.informativeText = failure.error
        } else {
            alert.messageText = "Couldn't extract \(failures.count) archives"
            alert.informativeText = failures.map { "\($0.source.lastPathComponent): \($0.error)" }
                .joined(separator: "\n\n")
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showProgress() {
        guard !list.jobs.isEmpty else { return }
        if let progress { progress.orderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Press"
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let host = NSHostingController(rootView: ExtractionProgressList(
            list: list, stop: { [weak self] job in self?.cancel(job) }))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        progress = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        if prompt == nil { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
    }

    private func closeProgress() {
        progress?.delegate = nil
        progress?.close()
        progress = nil
    }

    private func requestPassword(for job: DirectExtraction) {
        guard !job.cancelled else { job.model.submitPassword(nil); return }
        passwordRequests.append(job)
        showNextPrompt()
    }

    private func showNextPrompt() {
        guard prompt == nil, !passwordRequests.isEmpty else { return }
        let job = passwordRequests.removeFirst()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 388, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Extract \(job.source.lastPathComponent)"
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: PasswordPrompt(
            name: job.source.lastPathComponent, hint: job.model.passwordHint,
            submit: { [weak self] value in self?.submitPassword(value) }))
        prompt = panel
        promptJob = job
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func submitPassword(_ value: String?) {
        let job = promptJob
        closePrompt()
        if value == nil, let job { cancel(job) } else { job?.model.submitPassword(value) }
        showNextPrompt()
    }

    private func closePrompt() {
        prompt?.delegate = nil
        prompt?.close()
        prompt = nil
        promptJob = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === progress { cancelAll() } else { submitPassword(nil) }
        return false
    }
}

@MainActor
final class DirectExtraction: Identifiable {
    let source: URL
    let model = ArchiveModel()
    var cancelled = false

    init(source: URL) { self.source = source }
}

@MainActor @Observable
final class ExtractionList {
    var jobs: [DirectExtraction] = []
}

struct ExtractionProgressList: View {
    let list: ExtractionList
    let stop: (DirectExtraction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(list.jobs.enumerated()), id: \.element.id) { index, job in
                if index > 0 { Divider().padding(.horizontal, 16) }
                ExtractionProgress(model: job.model, source: job.source, stop: { stop(job) })
            }
        }
        .frame(width: 420)
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
    }

    private var detail: String {
        if model.phase == .password { return "Waiting for password…" }
        guard model.phase == .extracting, let written = model.extractedBytes else { return "Reading archive…" }
        let done = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
        guard let total = model.preview?.expandedSize else { return done }
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}
