import Foundation
import Testing
@testable import PressCore

let testRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let engine = Extractor(helperURL: testRoot.appendingPathComponent(".build/7zip/7zz"))

func fixture(_ name: String) throws -> URL {
    let path = try #require(ProcessInfo.processInfo.environment["PRESS_TEST_FIXTURES"], "Run ./scripts/test.sh")
    return URL(fileURLWithPath: path).appendingPathComponent(name)
}

struct Workspace {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func helper(_ script: String) throws -> URL {
        let url = root.appendingPathComponent("helper.sh")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }
    func copy(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixture(name), to: url)
        return url
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw ExtractionError(message: "Timed out waiting for the archive model.")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
