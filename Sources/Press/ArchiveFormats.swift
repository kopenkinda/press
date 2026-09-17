import Foundation

struct ArchiveFormat: Decodable {
    let name: String
    let extensions: [String]
}

enum ArchiveFormats {
    // Catalogue matches the pinned 7-Zip 26.03 runtime. Detection itself is
    // delegated to the engine, so unknown extensions remain openable.
    static let all: [ArchiveFormat] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "ArchiveFormats", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let formats = try? JSONDecoder().decode([ArchiveFormat].self, from: data) else { return [] }
        return formats
    }()
    static let extensions = Array(Set(all.flatMap(\.extensions))).sorted()

    static func isCompressedTar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["tgz", "tpz", "tbz", "tbz2", "txz", "tzst", "taz"].contains(url.pathExtension.lowercased())
            || ["gz", "gzip", "bz2", "bzip2", "xz", "zst", "z", "lzma", "lzma86"].contains {
                name.hasSuffix(".tar.\($0)")
            }
    }

    static func folderName(for source: URL) -> String {
        var stem = source.deletingPathExtension().lastPathComponent
        if isCompressedTar(source), stem.lowercased().hasSuffix(".tar") { stem = String(stem.dropLast(4)) }
        return stem.isEmpty ? "Archive" : stem
    }
}
