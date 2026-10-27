import AppKit
import Observation

@MainActor @Observable
final class ArchiveModel {
    enum Phase { case empty, loading, ready, extracting, preparingPreview, password, failed }
    private enum Operation: Sendable {
        case preview, extract(URL), quickLook(Int)
        var phase: Phase {
            switch self {
            case .preview: .loading
            case .extract: .extracting
            case .quickLook: .preparingPreview
            }
        }
        var isQuickLook: Bool {
            if case .quickLook = self { return true }
            return false
        }
        var isPreview: Bool {
            if case .preview = self { return true }
            return false
        }
    }
    private enum Result: Sendable { case preview(ArchivePreview), extracted(URL), quickLook(PreviewFile) }

    @ObservationIgnored private let extractor: Extractor

    init(extractor: Extractor = Extractor()) {
        self.extractor = extractor
    }

    private(set) var source: URL?
    private(set) var phase = Phase.empty
    private(set) var preview: ArchivePreview?
    private(set) var output: URL?
    // Logical bytes written so far while extracting.
    private(set) var extractedBytes: Int64?
    private(set) var message: String?
    private(set) var quickLookURL: URL?
    private(set) var quickLookEntryID: Int?
    @ObservationIgnored private var quickLookFile: PreviewFile?
    var needsPassword = false
    private(set) var passwordHint: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Result, Error>?
    @ObservationIgnored private var passwordReply: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var stopping = false
    // Windowless extraction uses the same password retry and safety flow as tabs.
    @ObservationIgnored var onPasswordRequest: (() -> Void)?
    @ObservationIgnored var onCompletion: ((String?) -> Void)?

    var isBusy: Bool { [.loading, .extracting, .preparingPreview, .password].contains(phase) }
    var canExtract: Bool { preview != nil && preview?.blockedReason == nil && !isBusy }
    var extractionProgress: Double? {
        guard let extractedBytes, let expanded = preview?.expandedSize, expanded > 0 else { return nil }
        return min(1, Double(extractedBytes) / Double(expanded))
    }

    func open(_ url: URL, behavior: OpenBehavior = .current) {
        guard source == nil else { return }
        source = url
        perform(.preview, then: behavior)
    }

    func reload() {
        guard !isBusy else { return }
        clearQuickLook()
        preview = nil
        output = nil
        perform(.preview)
    }

    func quickLook(_ entryID: Int) {
        guard !isBusy, let entry = preview?.entries.first(where: { $0.id == entryID }),
              !entry.isDirectory, !entry.isLink else { return }
        dismissQuickLook()
        perform(.quickLook(entryID))
    }

    func dismissQuickLook() {
        quickLookURL = nil
        quickLookEntryID = nil
    }

    func clearQuickLook() {
        dismissQuickLook()
        quickLookFile?.remove()
        quickLookFile = nil
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
        if !operation.isQuickLook { output = nil }
        phase = operation.phase
        task = Task {
            var previewCompleted = false
            var failure: String?
            defer {
                task = nil
                worker = nil
                extractedBytes = nil
                // Apply the opening preference once, only after a successful
                // inspection. Reloading a preview never extracts again.
                if previewCompleted && !stopping && canExtract && behavior == .extractBeside {
                    perform(.extract(source.deletingLastPathComponent()))
                } else {
                    if previewCompleted && !stopping && canExtract && behavior == .chooseDestination { chooseDestination() }
                    onCompletion?(failure ?? (previewCompleted ? preview?.blockedReason : nil))
                }
            }
            while !stopping {
                phase = operation.phase
                if case .extract = operation { extractedBytes = 0 }
                let attemptPassword = password
                let currentPreview = preview
                let extractor = extractor
                let report: @Sendable (Int64) -> Void = { bytes in
                    Task { @MainActor in
                        if self.phase == .extracting { self.extractedBytes = bytes }
                    }
                }
                let attempt = Task.detached(priority: .userInitiated) {
                    switch operation {
                    case .preview:
                        return Result.preview(try await extractor.inspect(source, password: attemptPassword))
                    case .extract(let destination):
                        guard let currentPreview else { throw ExtractionError(message: "Read the archive before extracting.") }
                        return Result.extracted(try await extractor.extract(source, to: destination,
                                                                          preview: currentPreview, password: attemptPassword,
                                                                          progress: report))
                    case .quickLook(let entryID):
                        guard let currentPreview else { throw ExtractionError(message: "Read the archive before previewing a file.") }
                        return Result.quickLook(try await extractor.preparePreview(source, entryID: entryID,
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
                    case .quickLook(let file):
                        quickLookFile?.remove()
                        quickLookFile = file
                        quickLookEntryID = file.entryID
                        quickLookURL = file.fileURL
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
                        onPasswordRequest?()
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
                    failure = error.localizedDescription
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
        clearQuickLook()
    }
}
