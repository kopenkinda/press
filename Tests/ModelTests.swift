import Foundation
import Testing
@testable import PressCore

// Opening preferences use UserDefaults, so these cases run one at a time and
// restore the test runner's original value. They never change Press's domain.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ModelTests {
    @Test func previewIsDefaultAndReloadNeverAutomaticallyExtracts() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: OpenBehavior.defaultsKey)
        defer { defaults.set(saved, forKey: OpenBehavior.defaultsKey) }
        defaults.removeObject(forKey: OpenBehavior.defaultsKey)
        #expect(OpenBehavior.current == .preview)
        defaults.set("obsolete-value", forKey: OpenBehavior.defaultsKey)
        #expect(OpenBehavior.current == .preview)
        let workspace = try Workspace()
        defer { workspace.remove() }
        let source = try workspace.copy("Tree.zip")
        let model = ArchiveModel(extractor: engine)
        defer { model.cancel() }
        model.open(source)
        try await waitUntil { !model.isBusy }
        #expect(model.phase == .ready)
        #expect(model.output == nil)
        #expect(model.canExtract)
        #expect(try workspace.names() == ["Tree.zip"])
        defaults.set(OpenBehavior.extractBeside.rawValue, forKey: OpenBehavior.defaultsKey)
        model.reload()
        try await waitUntil { !model.isBusy }
        #expect(model.output == nil)
        #expect(try workspace.names() == ["Tree.zip"])
        await model.stop()
    }

    @Test func extractBesideRunsOnceAfterInspectionAndRespectsBlockedArchives() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: OpenBehavior.defaultsKey)
        defer { defaults.set(saved, forKey: OpenBehavior.defaultsKey) }
        defaults.set(OpenBehavior.extractBeside.rawValue, forKey: OpenBehavior.defaultsKey)
        let workspace = try Workspace()
        defer { workspace.remove() }
        let model = ArchiveModel(extractor: engine)
        defer { model.cancel() }
        model.open(try workspace.copy("Tree.zip"))
        try await waitUntil { !model.isBusy }
        #expect(model.output?.lastPathComponent == "Tree")
        #expect(model.phase == .ready)
        model.reload()
        try await waitUntil { !model.isBusy }
        #expect(model.output == nil)
        #expect(try workspace.names() == ["Tree", "Tree.zip"])
        await model.stop()
        let blocked = ArchiveModel(extractor: engine)
        defer { blocked.cancel() }
        blocked.open(try workspace.copy("Link.tar"))
        try await waitUntil { !blocked.isBusy }
        #expect(blocked.preview?.blockedReason != nil)
        #expect(!blocked.canExtract)
        #expect(blocked.output == nil)
        #expect(try workspace.names() == ["Link.tar", "Tree", "Tree.zip"])
        await blocked.stop()
    }

    @Test func passwordRetryCancellationAndTabIsolation() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: OpenBehavior.defaultsKey)
        defer { defaults.set(saved, forKey: OpenBehavior.defaultsKey) }
        defaults.set(OpenBehavior.preview.rawValue, forKey: OpenBehavior.defaultsKey)
        let source = try fixture("Encrypted.7z")
        let first = ArchiveModel(extractor: engine)
        let second = ArchiveModel(extractor: engine)
        defer { first.cancel(); second.cancel() }
        first.open(source)
        try await waitUntil { first.needsPassword || !first.isBusy }
        try #require(first.needsPassword)
        #expect(!first.canExtract)
        #expect(first.passwordHint == nil)
        first.submitPassword("wrong")
        try await waitUntil { first.needsPassword || !first.isBusy }
        try #require(first.needsPassword)
        #expect(first.passwordHint != nil)
        first.submitPassword("secret")
        try await waitUntil { !first.isBusy }
        #expect(first.phase == .ready)
        #expect(first.canExtract)
        second.open(source)
        try await waitUntil { second.needsPassword || !second.isBusy }
        try #require(second.needsPassword) // No password leaks between archive tabs.
        second.submitPassword(nil)
        try await waitUntil { !second.isBusy }
        #expect(second.preview == nil)
        #expect(second.output == nil)
        #expect(!second.canExtract)
        #expect(first.canExtract)
        second.reload()
        try await waitUntil { second.needsPassword || !second.isBusy }
        try #require(second.needsPassword)
        await second.stop() // Closing a tab must also release a suspended password prompt.
        #expect(!second.needsPassword)
        #expect(!second.isBusy)
        await first.stop()
    }
}
