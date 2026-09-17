import AppKit
import Observation

@MainActor @Observable
final class ArchiveModel {
    enum Phase { case empty, loading, ready, extracting, password, failed }
    private enum Operation: Sendable {
        case preview, extract(URL)
        var isPreview: Bool {
            if case .preview = self { return true }
            return false
        }
    }
    private enum Result: Sendable { case preview(ArchivePreview), extracted(URL) }

    private(set) var source: URL?
    private(set) var phase = Phase.empty
    private(set) var preview: ArchivePreview?
    private(set) var output: URL?
    private(set) var message: String?
    var needsPassword = false
    private(set) var passwordHint: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Result, Error>?
    @ObservationIgnored private var passwordReply: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var stopping = false

    var isBusy: Bool { [.loading, .extracting, .password].contains(phase) }
    var canExtract: Bool { preview != nil && preview?.blockedReason == nil && !isBusy }

    func open(_ url: URL) {
        guard source == nil else { return }
        source = url
        perform(.preview, then: OpenBehavior.current)
    }

    func reload() {
        guard !isBusy else { return }
        preview = nil
        output = nil
        perform(.preview)
    }

    func chooseDestination() {
        guard canExtract, let source, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Extract archive"
        panel.prompt = "Extract"
        panel.message = "A new “\(ArchiveFormats.folderName(for: source))” folder will be created in the folder you choose."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = source.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let destination = panel.url { self?.perform(.extract(destination)) }
        }
    }

    private func perform(_ operation: Operation, then behavior: OpenBehavior = .preview) {
        guard !isBusy, !stopping, let source else { return }
        message = nil
        output = nil
        phase = operation.isPreview ? .loading : .extracting
        task = Task {
            var previewCompleted = false
            defer {
                task = nil
                worker = nil
                // Apply the opening preference once, only after a successful
                // inspection. Reloading a preview never extracts again.
                if previewCompleted && !stopping && canExtract {
                    switch behavior {
                    case .preview: break
                    case .extractBeside: perform(.extract(source.deletingLastPathComponent()))
                    case .chooseDestination: chooseDestination()
                    }
                }
            }
            while !stopping {
                phase = operation.isPreview ? .loading : .extracting
                let attemptPassword = password
                let currentPreview = preview
                let attempt = Task.detached(priority: .userInitiated) {
                    switch operation {
                    case .preview:
                        return Result.preview(try await Extractor.inspect(source, password: attemptPassword))
                    case .extract(let destination):
                        guard let currentPreview else { throw ExtractionError(message: "Read the archive before extracting.") }
                        return Result.extracted(try await Extractor.extract(source, to: destination,
                                                                          preview: currentPreview, password: attemptPassword))
                    }
                }
                worker = attempt
                do {
                    switch try await attempt.value {
                    case .preview(let value):
                        preview = value
                        previewCompleted = true
                    case .extracted(let folder): output = folder
                    }
                    phase = .ready
                } catch is PasswordRequired {
                    worker = nil
                    if stopping { break }
                    phase = .password
                    passwordHint = password == nil ? nil : "That password didn't work. Try again."
                    password = nil
                    let reply = await withCheckedContinuation { continuation in
                        passwordReply = continuation
                        needsPassword = true
                    }
                    if let reply { password = reply; continue }
                    phase = preview == nil ? .failed : .ready
                    message = "Cancelled. No files were extracted."
                } catch is CancellationError {
                    phase = preview == nil ? .failed : .ready
                    message = "Cancelled. No files were extracted."
                } catch {
                    phase = preview == nil ? .failed : .ready
                    message = error.localizedDescription
                }
                break
            }
        }
    }

    func submitPassword(_ value: String?) {
        let reply = passwordReply
        passwordReply = nil
        needsPassword = false
        reply?.resume(returning: value)
    }

    func cancel() {
        worker?.cancel()
        submitPassword(nil)
    }

    func stop() async {
        stopping = true
        cancel()
        await task?.value
        password = nil
    }
}
