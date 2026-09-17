import Foundation
import Testing
@testable import PressCore

@Suite(.timeLimit(.minutes(1)))
struct QuickLookTests {
    @Test(arguments: ["Tree.zip", "Tree.zipx", "Tree.tar.gz", "Tree.tar.xz", "Tree.tar.zst", "Plain.7z", "hello.txt.bz2"])
    func preparesOnlySelectedFileAndRemovesTemporaryCopy(name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy(name)
        let original = try Data(contentsOf: source)
        let preview = try await engine.inspect(source, password: nil)
        let entry = try #require(preview.entries.first { $0.path.hasSuffix("hello.txt") })
        let file = try await engine.preparePreview(source, entryID: entry.id, preview: preview, password: nil)
        defer { file.remove() }
        #expect(try String(contentsOf: file.fileURL, encoding: .utf8) == "Hello from Press.\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.fileURL.deletingLastPathComponent().path) == ["hello.txt"])
        #expect(try workspace.names() == [name])
        #expect(try Data(contentsOf: source) == original)
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.directory.path))
    }

    @Test(arguments: ["report?.txt", "report1.txt", "Folder/report*.txt", "Folder/report-all.txt", "@notes.txt", "-notes.txt", "A.txt", "a.txt", "café.txt", "Folder/café.txt", "カフェ.txt"])
    func selectionUsesLiteralArchivePath(path: String) async throws {
        let source = try fixture("LiteralNames.zip")
        let preview = try await engine.inspect(source, password: nil)
        let entry = try #require(preview.entries.first { $0.path == path })
        let file = try await engine.preparePreview(source, entryID: entry.id, preview: preview, password: nil)
        defer { file.remove() }
        #expect(try String(contentsOf: file.fileURL, encoding: .utf8) == path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.fileURL.deletingLastPathComponent().path).count == 1)
    }

    @Test(arguments: ["Encrypted.zip", "Encrypted.7z", "Encrypted.rar"])
    func supportsEncryptedFiles(name: String) async throws {
        let source = try fixture(name)
        let password = name.hasSuffix("rar") ? "12345678" : "secret"
        let preview = try await engine.inspect(source, password: name.hasSuffix("zip") ? nil : password)
        let entry = try #require(preview.entries.first { !$0.isDirectory })
        await #expect(throws: PasswordRequired.self) {
            try await engine.preparePreview(source, entryID: entry.id, preview: preview, password: "wrong")
        }
        let file = try await engine.preparePreview(source, entryID: entry.id, preview: preview, password: password)
        defer { file.remove() }
        #expect(try Int64(Data(contentsOf: file.fileURL).count) == entry.size)
    }

    @Test(arguments: ["Oversize.zip", "Link.tar"])
    func rejectsOversizeFilesAndLinks(name: String) async throws {
        let source = try fixture(name)
        let preview = try await engine.inspect(source, password: nil)
        let entry = try #require(preview.entries.first)
        await #expect(throws: ExtractionError.self) {
            try await engine.preparePreview(source, entryID: entry.id, preview: preview, password: nil)
        }
    }

    @Test func rejectsFoldersMissingSelectionsAndChangedArchives() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy("Tree.zip")
        let preview = try await engine.inspect(source, password: nil)
        let folder = try #require(preview.entries.first { $0.isDirectory })
        for id in [folder.id, -1] {
            await #expect(throws: ExtractionError.self) {
                try await engine.preparePreview(source, entryID: id, preview: preview, password: nil)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: preview.modified.addingTimeInterval(5)], ofItemAtPath: source.path)
        let file = try #require(preview.entries.first { !$0.isDirectory })
        await #expect(throws: ExtractionError.self) {
            try await engine.preparePreview(source, entryID: file.id, preview: preview, password: nil)
        }
    }

    @Test func previewLimitChecksActualOutput() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let file = workspace.root.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(Extractor.previewSizeLimit + 1))
        #expect(throws: ExtractionError.self) { try Extractor.checkOutput(workspace.root, limit: Extractor.previewSizeLimit) }
    }
}
