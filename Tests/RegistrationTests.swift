import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PressCore

struct RegistrationTests {
    @Test func finderRegistrationCoversCatalogueWithoutClaimingDefaults() throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let info = workspace.root.appendingPathComponent("Info.plist")
        try FileManager.default.copyItem(at: testRoot.appendingPathComponent("Resources/Info.plist"), to: info)
        func register() throws -> NSDictionary {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swift", testRoot.appendingPathComponent("scripts/register-formats.swift").path,
                                 testRoot.appendingPathComponent("Resources/ArchiveFormats.json").path, info.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? NSDictionary)
        }
        let metadata = try register()
        let documents = try #require(metadata["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(!documents.isEmpty)
        #expect(documents.allSatisfy { $0["CFBundleTypeRole"] as? String == "Viewer" && $0["LSHandlerRank"] as? String == "Alternate" })
        let registered = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let declarations = try #require(metadata["UTImportedTypeDeclarations"] as? [[String: Any]])
        var covered: Set<String> = []
        for declaration in declarations {
            guard let id = declaration["UTTypeIdentifier"] as? String, registered.contains(id),
                  let tags = declaration["UTTypeTagSpecification"] as? [String: Any],
                  let extensions = tags["public.filename-extension"] as? [String] else { continue }
            covered.formUnion(extensions)
        }
        for ext in ArchiveFormats.extensions {
            if let type = UTType(filenameExtension: ext), registered.contains(type.identifier) { covered.insert(ext) }
            #expect(covered.contains(ext), "Finder cannot offer Press for .\(ext)")
        }
        #expect(try register() == metadata) // Rebuilding must not drop imported types or accumulate duplicates.
    }
}
