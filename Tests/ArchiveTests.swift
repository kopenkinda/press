import Darwin
import Foundation
import Testing
@testable import PressCore

@Suite(.timeLimit(.minutes(1)))
struct ArchiveTests {
    @Test(arguments: ["Tree.zip", "Tree.zipx", "Tree.unknown", "Tree.tar", "Tree.tar.gz", "Tree.tar.bz2", "Tree.tar.xz", "Tree.tar.zst", "Tree.tgz"])
    func previewAndExtract(name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy(name)
        let original = try Data(contentsOf: source)
        let preview = try await engine.inspect(source, password: nil)
        #expect(try workspace.names() == [name]) // Preview must not extract beside the archive.
        #expect(preview.blockedReason == nil)
        #expect(preview.expandedSize == 43)
        #expect(preview.roots.map(\.name) == ["Empty", "Folder", "notes.txt"])
        #expect(preview.roots[0].children?.isEmpty == true)
        #expect(preview.roots[1].children?.map(\.name) == ["café.txt", "hello.txt"])
        let output = try await engine.extract(source, to: workspace.root, preview: preview, password: nil)
        #expect(output.lastPathComponent == "Tree")
        #expect(try String(contentsOf: output.appendingPathComponent("Folder/hello.txt"), encoding: .utf8) == "Hello from Press.\n")
        #expect(try String(contentsOf: output.appendingPathComponent("Folder/café.txt"), encoding: .utf8) == "Unicode filename.\n")
        #expect(try String(contentsOf: output.appendingPathComponent("notes.txt"), encoding: .utf8) == "Notes.\n")
        #expect(try Data(contentsOf: source) == original)
        #expect(try workspace.names() == ["Tree", name].sorted())
    }

    @Test(arguments: ["hello.txt.gz", "hello.txt.bz2", "hello.txt.xz", "hello.txt.zst", "Plain.7z"])
    func singleFileCompressors(name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try fixture(name)
        let preview = try await engine.inspect(source, password: nil)
        #expect(preview.entries.count == 1)
        #expect(preview.entries.first?.path == "hello.txt")
        let output = try await engine.extract(source, to: workspace.root, preview: preview, password: nil)
        #expect(try String(contentsOf: output.appendingPathComponent("hello.txt"), encoding: .utf8) == "Hello from Press.\n")
    }

    @Test(arguments: ["Encrypted.7z", "Encrypted.rar"])
    func encryptedHeadersRequirePasswordAndAllowRetry(name: String) async throws {
        let source = try fixture(name)
        await #expect(throws: PasswordRequired.self) { try await engine.inspect(source, password: nil) }
        await #expect(throws: PasswordRequired.self) { try await engine.inspect(source, password: "wrong") }
        let password = name.hasSuffix("rar") ? "12345678" : "secret"
        let preview = try await engine.inspect(source, password: password)
        let workspace = try Workspace()
        defer { workspace.remove() }
        let output = try await engine.extract(source, to: workspace.root, preview: preview, password: password)
        if name.hasSuffix("rar") {
            #expect(try String(contentsOf: output.appendingPathComponent("foo.txt"), encoding: .utf8) == "data of foo.txt\n")
            #expect(try String(contentsOf: output.appendingPathComponent("bar.txt"), encoding: .utf8) == "data of bar.txt\n")
        } else {
            #expect(try String(contentsOf: output.appendingPathComponent("hello.txt"), encoding: .utf8) == "Hello from Press.\n")
        }
    }

    @Test func encryptedContentsPromptAtExtractionAndCleanFailedOutput() async throws {
        let source = try fixture("Encrypted.zip")
        let preview = try await engine.inspect(source, password: nil)
        #expect(preview.entries.first?.encrypted == true)
        let workspace = try Workspace()
        defer { workspace.remove() }
        for password in [nil, "wrong"] as [String?] {
            await #expect(throws: PasswordRequired.self) {
                try await engine.extract(source, to: workspace.root, preview: preview, password: password)
            }
            #expect(try workspace.names().isEmpty)
        }
        let output = try await engine.extract(source, to: workspace.root, preview: preview, password: "secret")
        #expect(try String(contentsOf: output.appendingPathComponent("hello.txt"), encoding: .utf8) == "Hello from Press.\n")
    }

    @Test(arguments: [false, true])
    func neverOverwritesDestinationOrUsesStalePreview(changeDateOnly: Bool) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy("Tree.zip")
        let existing = workspace.root.appendingPathComponent("Tree")
        try Data("Keep me".utf8).write(to: existing) // A file collision must also be preserved.
        let preview = try await engine.inspect(source, password: nil)
        let output = try await engine.extract(source, to: workspace.root, preview: preview, password: nil)
        #expect(output.lastPathComponent == "Tree 2")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "Keep me")
        if changeDateOnly {
            try FileManager.default.setAttributes([.modificationDate: preview.modified.addingTimeInterval(5)], ofItemAtPath: source.path)
        } else {
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
        }
        await #expect(throws: ExtractionError.self) {
            try await engine.extract(source, to: workspace.root, preview: preview, password: nil)
        }
        #expect(try workspace.names() == ["Tree", "Tree 2", "Tree.zip"])
    }

    @Test(arguments: ["Traversal.zip", "Many.zip", "Broken.zip", "Broken.tar.gz"])
    func rejectsUnsafeOrUnreadableArchives(name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy(name)
        await #expect(throws: ExtractionError.self) { try await engine.inspect(source, password: nil) }
        #expect(try workspace.names() == [name])
    }

    @Test(arguments: ["Link.tar", "Oversize.zip", "Overlap.zip"])
    func blocksExtractionOfLinksAndOversizeArchives(name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try fixture(name)
        let preview = try await engine.inspect(source, password: nil)
        #expect(preview.blockedReason != nil)
        await #expect(throws: ExtractionError.self) {
            try await engine.extract(source, to: workspace.root, preview: preview, password: nil)
        }
        #expect(try workspace.names().isEmpty)
    }

    @Test func cancellationRemovesPartialExtraction() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try fixture("Tree.tar.gz")
        let preview = try await engine.inspect(source, password: nil)
        let task = Task { try await engine.extract(source, to: workspace.root, preview: preview, password: nil) }
        // The real helper starts immediately; its monitor yields for 200 ms.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try workspace.names().isEmpty)
    }

    @Test func sandboxConfinesHelperWritesToExtractionFolder() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy("Tree.zip")
        let helper = try workspace.helper("""
        if [ "$1" = l ]; then
            printf 'Path = file.txt\nSize = 2\n'
        else
            for arg; do
                case "$arg" in -o*) output="${arg#-o}" ;; esac
                source="$arg"
            done
            printf ok > "$output/file.txt" || exit 1
            printf escape > "${source%/*}/outside.txt"
        fi
        exit 0
        """)
        let probe = Extractor(helperURL: helper)
        let preview = try await probe.inspect(source, password: nil)
        let output = try await probe.extract(source, to: workspace.root, preview: preview, password: nil)
        #expect(try String(contentsOf: output.appendingPathComponent("file.txt"), encoding: .utf8) == "ok")
        #expect(!FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("outside.txt").path))
    }

    @Test func oversizedHelperLogIsStoppedBeforeParsing() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy("Tree.zip")
        let helper = try workspace.helper("/usr/bin/head -c 17000000 /dev/zero")
        do {
            _ = try await Extractor(helperURL: helper).inspect(source, password: nil)
            Issue.record("An oversized listing was accepted.")
        } catch let error as ExtractionError {
            #expect(error.message.contains("listing is too large"))
        }
    }

}
