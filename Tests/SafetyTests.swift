import Darwin
import Foundation
import Testing
@testable import PressCore

struct SafetyTests {
    @Test(arguments: ["../escape", "/absolute", "folder/../../escape", "C:/escape", "folder\\escape",
                      String(repeating: "a/", count: 65) + "file", String(repeating: "a", count: 4097)])
    func rejectsUnsafePaths(path: String) {
        #expect(throws: ExtractionError.self) {
            try Extractor.parseListing("Path = \(path)\nSize = 1\n", fallbackName: "unused")
        }
    }

    @Test(arguments: ["Path = a\nPath = b\n", "Path = a\nSize = -1\n", "Path = a\nSize = 99999999999999999999\n",
                      "Path = a\nSize = invalid\n", "Path = line\nbreak\nSize = 1\n"])
    func rejectsAmbiguousOrInvalidMetadata(listing: String) {
        #expect(throws: ExtractionError.self) { try Extractor.parseListing(listing, fallbackName: "unused") }
    }

    @Test func tarMetadataAndUnknownStreamSize() throws {
        let entries = try Extractor.parseListing("""
        Path = Empty
        Mode = drwxr-xr-x
        Size = 0
        Symbolic Link = 
        Hard Link = 

        Path = file
        Mode = -rw-r--r--
        Size = 3
        Symbolic Link = 
        Hard Link = 

        Path = link
        Symbolic Link = file
        Size = 0
        """, fallbackName: "unused")
        #expect(entries[0].isDirectory)
        #expect(!entries[1].isLink)
        #expect(entries[2].isLink)
        let stream = try Extractor.parseListing("Size = \nPacked Size = 24\n", fallbackName: "hello.txt")
        #expect(stream.first?.path == "hello.txt")
        #expect(stream.first?.size == nil)
    }

    @Test func mergesExplicitAndInferredFolders() throws {
        let entries = try Extractor.parseListing("""
        Path = ./Folder/Sub/file.txt
        Size = 2

        Path = Folder
        Folder = +
        Size = 0

        Path = Empty
        Folder = +
        Size = 0
        """, fallbackName: "unused")
        let tree = try ArchiveNode.tree(from: entries)
        #expect(tree.map(\.name) == ["Empty", "Folder"])
        #expect(tree[0].children?.isEmpty == true)
        #expect(tree[1].children?.first?.children?.first?.name == "file.txt")
    }

    @Test func countsImplicitFoldersTowardEntryLimit() throws {
        let entries = (0..<5001).map {
            ArchiveEntry(id: $0, path: "folder\($0)/file", size: 0, isDirectory: false, encrypted: false, isLink: false)
        }
        #expect(throws: ExtractionError.self) { try ArchiveNode.tree(from: entries) }
    }

    @Test func checksActualLogicalSizeIncludingSparseFiles() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let file = workspace.root.appendingPathComponent("sparse")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let limit = Extractor.expansionLimit(archiveSize: 1_000)
        try handle.truncate(atOffset: UInt64(limit))
        #expect(try Extractor.checkOutput(workspace.root, limit: limit) == limit)
        try handle.truncate(atOffset: UInt64(limit + 1))
        #expect(throws: ExtractionError.self) { try Extractor.checkOutput(workspace.root, limit: limit) }
    }

    @Test func expansionLimitAllowsSmallArchivesAndScalesWithSize() {
        #expect(Extractor.expansionLimit(archiveSize: 0) == Extractor.expansionAllowance)
        #expect(Extractor.expansionLimit(archiveSize: 1_000) == Extractor.expansionAllowance)
        #expect(Extractor.expansionLimit(archiveSize: 50_000_000) == 50_000_000_000)
        #expect(Extractor.expansionLimit(archiveSize: .max / 2) == .max)
    }

    @Test func detectsOverlappingZipEntries() throws {
        func listing(_ entries: [(offset: Int, packed: Int, volume: Int)]) throws -> [ArchiveEntry] {
            try Extractor.parseListing(entries.enumerated().map { index, entry in
                "Path = \(index)\nSize = 1\nPacked Size = \(entry.packed)\nOffset = \(entry.offset)\nVolume Index = \(entry.volume)\n"
            }.joined(separator: "\n"), fallbackName: "unused")
        }
        #expect(!Extractor.hasOverlappingEntries(try listing([(0, 100, 0), (130, 50, 0), (200, 0, 0)])))
        #expect(!Extractor.hasOverlappingEntries(try listing([(0, 100, 0), (0, 100, 1)])))
        #expect(Extractor.hasOverlappingEntries(try listing([(0, 100, 0), (0, 100, 0)])))
        #expect(Extractor.hasOverlappingEntries(try listing([(0, 100, 0), (60, 100, 0)])))
        // Formats without offsets, such as solid 7z, are not checked.
        let solid = try Extractor.parseListing("Path = a\nSize = 1\nPacked Size = 9\n\nPath = b\nSize = 1\n", fallbackName: "unused")
        #expect(!Extractor.hasOverlappingEntries(solid))
    }

    @Test func rejectsLinksSpecialFilesAndTooManyOutputEntries() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let link = workspace.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
        #expect(throws: ExtractionError.self) { try Extractor.checkOutput(workspace.root) }
        try FileManager.default.removeItem(at: link)
        let fifo = workspace.root.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ExtractionError.self) { try Extractor.checkOutput(workspace.root) }
        try FileManager.default.removeItem(at: fifo)
        for index in 0...Extractor.entryLimit {
            FileManager.default.createFile(atPath: workspace.root.appendingPathComponent("\(index)").path, contents: nil)
        }
        #expect(throws: ExtractionError.self) { try Extractor.checkOutput(workspace.root) }
    }

    @Test func formatCatalogueAndOutputNames() {
        #expect(!ArchiveFormats.all.isEmpty)
        #expect(Set(["rar", "zip", "zipx", "7z", "tar", "gz", "bz2", "xz", "zst", "iso", "dmg"]).isSubset(of: Set(ArchiveFormats.extensions)))
        for name in ["Photos.tar.gz", "Photos.TAR.XZ", "Photos.tgz", "Photos.tbz2", "Photos.txz", "Photos.tzst"] {
            let url = URL(fileURLWithPath: name)
            #expect(ArchiveFormats.isCompressedTar(url))
            #expect(ArchiveFormats.folderName(for: url) == "Photos")
        }
        #expect(!ArchiveFormats.isCompressedTar(URL(fileURLWithPath: "data.gz")))
        #expect(ArchiveFormats.folderName(for: URL(fileURLWithPath: "hello.txt.gz")) == "hello.txt")
    }
}
