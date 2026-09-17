import Darwin
import Foundation

struct ExtractionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct PasswordRequired: Error {}

struct ArchiveEntry: Identifiable, Sendable {
    let id: Int
    let path: String
    let size: Int64?
    let isDirectory: Bool
    let encrypted: Bool
    let isLink: Bool
}

struct ArchiveNode: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let size: Int64?
    let encrypted: Bool
    let children: [ArchiveNode]?
    var isDirectory: Bool { children != nil }

    static func tree(from entries: [ArchiveEntry]) throws -> [ArchiveNode] {
        // Archives often omit directory entries. Build those parents once and
        // merge explicit directory records into the same folders.
        final class Folder {
            let path: String
            var folders: [Folder] = []
            var files: [ArchiveNode] = []
            var encrypted = false
            init(path: String) { self.path = path }

            func contents() -> [ArchiveNode] {
                let directories = folders.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                let documents = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return directories.map {
                    ArchiveNode(id: "folder:\($0.path)", name: String($0.path.split(separator: "/").last!),
                                path: $0.path, size: 0, encrypted: $0.encrypted, children: $0.contents())
                } + documents
            }
        }
        let root = Folder(path: "")
        var folders = ["": root]
        var nodeCount = 0
        for entry in entries {
            try Task.checkCancellation()
            let parts = entry.path.split(separator: "/").map(String.init).filter { $0 != "." }
            guard let name = parts.last else { continue }
            let parentParts = entry.isDirectory ? parts[...] : parts.dropLast()
            var parent = root
            var path = ""
            for component in parentParts {
                path = path.isEmpty ? component : "\(path)/\(component)"
                if let existing = folders[path] { parent = existing }
                else {
                    let folder = Folder(path: path)
                    parent.folders.append(folder)
                    folders[path] = folder
                    parent = folder
                    nodeCount += 1
                }
            }
            if entry.isDirectory { parent.encrypted = entry.encrypted }
            else {
                parent.files.append(ArchiveNode(id: "file:\(entry.id)", name: name, path: entry.path,
                                               size: entry.size, encrypted: entry.encrypted, children: nil))
                nodeCount += 1
            }
            guard nodeCount <= Extractor.entryLimit else {
                throw ExtractionError(message: "Including folders, this archive exceeds the 10,000-entry limit.")
            }
        }
        return root.contents()
    }
}

struct ArchivePreview: Sendable {
    let entries: [ArchiveEntry]
    let roots: [ArchiveNode]
    let expandedSize: Int64?
    let archiveSize: Int64
    let modified: Date
    let blockedReason: String?
}

// One private file owned by an archive tab. Explicit removal handles tab
// closure; deinit also cleans up a result discarded during cancellation.
final class PreviewFile: Sendable {
    let fileURL: URL
    let entryID: Int
    let directory: URL

    init(fileURL: URL, entryID: Int, directory: URL) {
        self.fileURL = fileURL
        self.entryID = entryID
        self.directory = directory
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}

struct Extractor: Sendable {
    let helperURL: URL?

    init(helperURL: URL? = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("7zz")) {
        self.helperURL = helperURL
    }

    static let sizeLimit: Int64 = 10_000_000_000
    static let entryLimit = 10_000
    static let previewSizeLimit: Int64 = 100_000_000
    private static let logLimit: Int64 = 16 * 1024 * 1024

    func inspect(_ source: URL, password: String?) async throws -> ArchivePreview {
        var source = source
        source.removeAllCachedResourceValues()
        try Self.validate(source)
        let original = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let staging = try Self.temporaryFolder(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = try await run(["l", "-slt", "-ba"], source: source, password: password, staging: staging)
        let entries = try Self.parseListing(output, fallbackName: source.deletingPathExtension().lastPathComponent)
        var total: Int64 = 0
        var knownSize = true
        var blocked: String?
        for entry in entries {
            if entry.size == nil && !entry.isDirectory { knownSize = false }
            let sum = total.addingReportingOverflow(entry.size ?? 0)
            guard !sum.overflow else { throw ExtractionError(message: "The archive reports an invalid expanded size.") }
            total = sum.partialValue
            if entry.isLink { blocked = "This archive contains links. This prototype only extracts files and folders." }
        }
        if total > Self.sizeLimit { blocked = "The reported expanded size exceeds this prototype's 10 GB limit." }
        source.removeAllCachedResourceValues()
        let current = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard current.fileSize == original.fileSize, current.contentModificationDate == original.contentModificationDate else {
            throw ExtractionError(message: "The archive changed while it was being read. Reload the preview.")
        }
        return ArchivePreview(entries: entries, roots: try ArchiveNode.tree(from: entries),
                              expandedSize: knownSize ? total : nil, archiveSize: Int64(current.fileSize ?? 0),
                              modified: current.contentModificationDate ?? .distantPast, blockedReason: blocked)
    }

    func extract(_ source: URL, to parent: URL, preview: ArchivePreview, password: String?) async throws -> URL {
        // Reusing the URL from preview can otherwise reuse stale file metadata.
        var source = source
        source.removeAllCachedResourceValues()
        try Self.validate(source)
        if let reason = preview.blockedReason { throw ExtractionError(message: reason) }
        let current = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard Int64(current.fileSize ?? 0) == preview.archiveSize,
              current.contentModificationDate == preview.modified else {
            throw ExtractionError(message: "The archive changed. Reload its preview before extracting.")
        }
        let parent = parent.resolvingSymlinksInPath()
        if let available = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(available) < (preview.expandedSize ?? 0) + 100_000_000 {
            throw ExtractionError(message: "There isn't enough free space in that destination.")
        }
        let staging = try Self.temporaryFolder(in: parent)
        defer { try? FileManager.default.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        _ = try await run(["x", "-y", "-aou", "-bb0", "-snld0", "-o\(contents.path)"],
                          source: source, password: password, staging: staging, contents: contents)
        try Self.checkOutput(contents)
        let name = ArchiveFormats.folderName(for: source)
        for suffix in 1...10_000 {
            try Task.checkCancellation()
            let folder = parent.appendingPathComponent(suffix == 1 ? name : "\(name) \(suffix)", isDirectory: true)
            if renamex_np(contents.path, folder.path, UInt32(RENAME_EXCL)) == 0 { return folder }
            if errno != EEXIST {
                throw ExtractionError(message: "Couldn't save the extracted folder: \(String(cString: strerror(errno)))")
            }
        }
        throw ExtractionError(message: "Too many folders already have this archive's name.")
    }

    func preparePreview(_ source: URL, entryID: Int, preview: ArchivePreview, password: String?) async throws -> PreviewFile {
        var source = source
        source.removeAllCachedResourceValues()
        try Self.validate(source)
        let current = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard Int64(current.fileSize ?? 0) == preview.archiveSize, current.contentModificationDate == preview.modified else {
            throw ExtractionError(message: "The archive changed. Reload its preview before opening a file.")
        }
        guard let entry = preview.entries.first(where: { $0.id == entryID }), !entry.isDirectory, !entry.isLink,
              preview.entries.filter({ $0.path == entry.path }).count == 1 else {
            throw ExtractionError(message: "Choose a single file with a unique path to preview.")
        }
        guard (entry.size ?? 0) <= Self.previewSizeLimit else {
            throw ExtractionError(message: "Quick Look previews are limited to 100 MB per file.")
        }
        let staging = try Self.temporaryFolder(in: FileManager.default.temporaryDirectory)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: staging) } }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        // Process normalizes macOS command-line arguments to decomposed Unicode.
        // A UTF-8 list file preserves the archive's exact spelling, including
        // composed accents. Wildcard matching and recursion stay disabled.
        let selection = staging.appendingPathComponent("selection.txt")
        try Data((entry.path + "\n").utf8).write(to: selection)
        _ = try await run(["e", "-y", "-aou", "-bb0", "-snld0", "-spd", "-ssc", "-r-", "-scsUTF-8",
                           "-i@\(selection.path)", "-o\(contents.path)"],
                          source: source, password: password, staging: staging, contents: contents,
                          outputLimit: Self.previewSizeLimit, timeLimit: 60)
        try Self.checkOutput(contents, limit: Self.previewSizeLimit)
        let files = try FileManager.default.contentsOfDirectory(at: contents, includingPropertiesForKeys: [.isRegularFileKey])
        guard files.count == 1, let file = files.first,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              file.lastPathComponent == entry.path.split(separator: "/").last.map(String.init) else {
            throw ExtractionError(message: "Couldn't isolate this file for Quick Look.")
        }
        try Task.checkCancellation()
        keep = true
        return PreviewFile(fileURL: file, entryID: entry.id, directory: staging)
    }

    private static func validate(_ source: URL) throws {
        guard source.isFileURL else {
            throw ExtractionError(message: "Choose a local archive or container file.")
        }
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ExtractionError(message: "Choose an archive file, not a folder.")
        }
    }

    private static func temporaryFolder(in parent: URL) throws -> URL {
        // Foundation preserves aliases such as /var on macOS. Sandbox path
        // rules need the actual /private/var path, including for temporary files.
        guard let canonicalParent = realpath(parent.path, nil) else {
            throw ExtractionError(message: "Couldn't resolve the destination folder.")
        }
        defer { free(canonicalParent) }
        var template = Array((String(cString: canonicalParent) + "/.press-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else {
            throw ExtractionError(message: "Couldn't create a temporary folder. Choose a writable destination with free space.")
        }
        return URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
    }

    private func run(_ arguments: [String], source: URL, password: String?, staging: URL, contents: URL? = nil,
                     outputLimit: Int64 = sizeLimit, timeLimit: TimeInterval? = nil) async throws -> String {
        guard let helper = helperURL,
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ExtractionError(message: "The extraction helper is missing. Rebuild Press and try again.")
        }
        guard (password?.utf8.count ?? 0) <= 4096, password?.contains(where: { $0 == "\n" || $0 == "\r" }) != true else {
            throw ExtractionError(message: "This prototype supports passwords up to 4 KB without line breaks.")
        }
        let logURL = staging.appendingPathComponent("output.log")
        let decoderLogURL = staging.appendingPathComponent("decoder.log")
        for url in [logURL, decoderLogURL] { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        let decoderLog = try FileHandle(forWritingTo: decoderLogURL)
        defer { try? log.close(); try? decoderLog.close() }
        let input = Pipe()
        let decoderInput = Pipe()
        defer { try? input.fileHandleForWriting.close(); try? decoderInput.fileHandleForWriting.close() }

        func makeProcess(_ command: [String], input: Pipe, output: Any, errorLog: FileHandle,
                         errorURL: URL, canWrite: Bool) -> Process {
            let process = Process()
            let writeRule = canWrite ? "(allow file-write* (subpath (param \"OUTPUT\")))" : ""
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-D", "OUTPUT=\(staging.path)", "-D", "LOG=\(errorURL.path)", "-p",
                "(version 1)(allow default)(deny network*)(deny file-write*)\(writeRule)(allow file-write-data (literal (param \"LOG\")))",
                helper.path] + command
            process.environment = ProcessInfo.processInfo.environment.merging(["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]) { _, new in new }
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorLog
            return process
        }

        let wrapped = ArchiveFormats.isCompressedTar(source)
        let command = arguments + ["-bd", "-sccUTF-8"] + (wrapped ? ["-ttar", "-si"] : ["--", source.path])
        let process = makeProcess(command, input: input, output: log, errorLog: log, errorURL: logURL, canWrite: contents != nil)
        let decoded = Pipe()
        let decoder = wrapped ? makeProcess(["x", "-so", "-y", "-bd", "-bb0", "-bso0", "-bse2", "-t*", "--", source.path],
            input: decoderInput, output: decoded, errorLog: decoderLog, errorURL: decoderLogURL, canWrite: false) : nil
        var stream: Task<Void, Error>?
        var decoderStarted = false
        let started = Date()
        try Task.checkCancellation()
        try process.run()
        do {
            if let decoder {
                try decoder.run()
                decoderStarted = true
                // Feed the inner TAR through a bounded pipe. No expanded TAR
                // is written to disk, and every decompressed byte is counted.
                let sink = input.fileHandleForWriting
                let reader = decoded.fileHandleForReading
                _ = fcntl(sink.fileDescriptor, F_SETNOSIGPIPE, 1)
                stream = Task.detached {
                    defer { try? sink.close(); try? reader.close() }
                    do {
                        var count: Int64 = 0
                        while let block = try reader.read(upToCount: 64 * 1024), !block.isEmpty {
                            guard Int64(block.count) <= Self.sizeLimit - count else {
                                throw ExtractionError(message: "The decompressed TAR stream exceeds the 10 GB limit.")
                            }
                            count += Int64(block.count)
                            try sink.write(contentsOf: block)
                        }
                    } catch {
                        if decoder.isRunning { kill(decoder.processIdentifier, SIGKILL) }
                        throw error
                    }
                }
                try decoderInput.fileHandleForWriting.write(contentsOf: Data(((password ?? "") + "\n").utf8))
                try decoderInput.fileHandleForWriting.close()
            } else {
                try input.fileHandleForWriting.write(contentsOf: Data(((password ?? "") + "\n").utf8))
                try input.fileHandleForWriting.close()
            }
            repeat {
                try Task.checkCancellation()
                for var url in [logURL, decoderLogURL] {
                    url.removeAllCachedResourceValues()
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.logLimit else {
                        throw ExtractionError(message: "The archive's listing is too large for this prototype.")
                    }
                }
                if let contents { try Self.checkOutput(contents, limit: outputLimit) }
                if Date().timeIntervalSince(started) > (timeLimit ?? (contents == nil ? 60 : .infinity)) {
                    throw ExtractionError(message: "Reading the archive took too long. The preview was stopped.")
                }
                if process.isRunning || decoder?.isRunning == true { try await Task.sleep(for: .milliseconds(200)) }
            } while process.isRunning || decoder?.isRunning == true
            try Task.checkCancellation()
        } catch {
            let children = [process, decoderStarted ? decoder : nil].compactMap { $0 }
            for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
            // Process updates isRunning after reaping. Blocking waitUntilExit
            // can hang when an async task resumes on a different thread.
            // Cleanup must finish even when the caller has been cancelled.
            await Task.detached {
                while children.contains(where: { $0.isRunning }) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }.value
            _ = try? await stream?.value
            throw error
        }
        var streamError: Error?
        do { try await stream?.value } catch { streamError = error }
        if let error = streamError as? ExtractionError { throw error }
        for var url in [logURL, decoderLogURL] {
            url.removeAllCachedResourceValues()
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.logLimit else {
                throw ExtractionError(message: "The archive's listing is too large for this prototype.")
            }
        }
        let output = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
        guard process.terminationStatus == 0, decoder == nil || decoder?.terminationStatus == 0 else {
            let diagnostics = output + String(decoding: try Data(contentsOf: decoderLogURL), as: UTF8.self)
            let lower = diagnostics.lowercased()
            if lower.contains("wrong password") || (password == nil && lower.contains("enter password")) { throw PasswordRequired() }
            let errors = diagnostics.components(separatedBy: .newlines).filter {
                $0.contains("ERROR") || $0.contains("Error") || $0.contains("Cannot") || $0.contains("Unexpected")
            }.prefix(4).joined(separator: "\n")
            throw ExtractionError(message: errors.isEmpty ? "Couldn't read this file. It may be unsupported, damaged, or incomplete." : errors)
        }
        if let streamError { throw streamError }
        return output
    }

    static func parseListing(_ output: String, fallbackName: String) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]
        func finish() throws {
            guard !fields.isEmpty else { return }
            // Single-file compressors such as XZ don't store a filename or,
            // for some codecs, an expanded size. Runtime limits still apply.
            let path = fields["Path"] ?? fallbackName
            let size = fields["Size"].flatMap(Int64.init)
            if let reported = fields["Size"], !reported.isEmpty, size == nil || size! < 0 {
                throw ExtractionError(message: "An entry reports an invalid expanded size.")
            }
            let components = path.split(separator: "/")
            guard !path.isEmpty, path.utf8.count <= 4096, components.count <= 64,
                  !path.hasPrefix("/"), !path.contains("\\"), !components.contains(".."),
                  components.first?.contains(":") != true else {
                throw ExtractionError(message: "This archive contains an unsafe or unsupported file path.")
            }
            guard entries.count < entryLimit else {
                throw ExtractionError(message: "This archive exceeds the prototype's limit of 10,000 entries.")
            }
            let attributes = fields["Attributes"] ?? fields["Mode"] ?? ""
            entries.append(ArchiveEntry(id: entries.count, path: path, size: size,
                isDirectory: fields["Folder"] == "+" || attributes.hasPrefix("D") || attributes.hasPrefix("d") || attributes.contains(" d"),
                encrypted: fields["Encrypted"] == "+",
                isLink: fields["Symbolic Link"]?.isEmpty == false || fields["Hard Link"]?.isEmpty == false
                    || attributes.hasPrefix("l") || attributes.contains(" l")))
            fields.removeAll()
        }
        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty { try finish(); continue }
            guard let separator = line.range(of: " = ") else {
                if line == "Enter password:" { continue }
                throw ExtractionError(message: "The archive's file listing couldn't be read safely.")
            }
            let key = String(line[..<separator.lowerBound])
            guard fields[key] == nil else { throw ExtractionError(message: "The archive contains an ambiguous file listing.") }
            fields[key] = String(line[separator.upperBound...])
        }
        try finish()
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // Header sizes are untrusted. Monitor actual logical sizes and entry count
    // while the helper runs, and check again before publishing the result.
    static func checkOutput(_ contents: URL, limit: Int64 = sizeLimit) throws {
        var enumerationError: Error?
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ExtractionError(message: "Couldn't read the extracted folder.")
        }
        var count = 0
        var size: Int64 = 0
        while let file = files.nextObject() as? URL {
            try Task.checkCancellation()
            count += 1
            guard count <= entryLimit else { throw ExtractionError(message: "Extraction stopped at the 10,000-entry limit.") }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw ExtractionError(message: "This archive contains links or special files that Press doesn't extract.")
            }
            if values.isRegularFile == true {
                guard let fileSize = values.fileSize, fileSize >= 0 else {
                    throw ExtractionError(message: "Couldn't determine the extracted file's size.")
                }
                guard Int64(fileSize) <= limit - size else {
                    throw ExtractionError(message: limit == previewSizeLimit ? "Quick Look previews are limited to 100 MB per file." : "Extraction stopped because the output exceeded 10 GB.")
                }
                size += Int64(fileSize)
            }
        }
        if let enumerationError { throw enumerationError }
    }
}
