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

    @Test func dropPreferenceIsIndependentOfOpeningPreference() async throws {
        let defaults = UserDefaults.standard
        let openSaved = defaults.object(forKey: OpenBehavior.defaultsKey)
        let dropSaved = defaults.object(forKey: OpenBehavior.dropDefaultsKey)
        defer {
            defaults.set(openSaved, forKey: OpenBehavior.defaultsKey)
            defaults.set(dropSaved, forKey: OpenBehavior.dropDefaultsKey)
        }
        defaults.set(OpenBehavior.extractBeside.rawValue, forKey: OpenBehavior.defaultsKey)
        defaults.removeObject(forKey: OpenBehavior.dropDefaultsKey)
        #expect(OpenBehavior.current == .extractBeside)
        #expect(OpenBehavior.onDrop == .preview)
        let workspace = try Workspace()
        defer { workspace.remove() }
        let dropped = ArchiveModel(extractor: engine)
        dropped.open(try workspace.copy("Tree.zip"), behavior: .onDrop)
        try await waitUntil { !dropped.isBusy }
        #expect(dropped.canExtract)
        #expect(dropped.output == nil)
        #expect(try workspace.names() == ["Tree.zip"])
        await dropped.stop()
        defaults.set(OpenBehavior.chooseDestination.rawValue, forKey: OpenBehavior.dropDefaultsKey)
        #expect(OpenBehavior.onDrop == .chooseDestination)
        #expect(OpenBehavior.current == .extractBeside)
        defaults.set("obsolete", forKey: OpenBehavior.dropDefaultsKey)
        #expect(OpenBehavior.onDrop == .preview)
    }

    @Test func quickLookRetriesPasswordAndCleansUpWithTab() async throws {
        let model = ArchiveModel(extractor: engine)
        defer { model.cancel() }
        model.open(try fixture("Encrypted.zip"), behavior: .preview)
        try await waitUntil { !model.isBusy }
        let entry = try #require(model.preview?.entries.first)
        model.quickLook(entry.id)
        try await waitUntil { model.needsPassword || !model.isBusy }
        try #require(model.needsPassword)
        model.submitPassword("wrong")
        try await waitUntil { model.needsPassword || !model.isBusy }
        try #require(model.needsPassword)
        #expect(model.passwordHint != nil)
        model.submitPassword("secret")
        try await waitUntil { !model.isBusy }
        let url = try #require(model.quickLookURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Hello from Press.\n")
        #expect(model.output == nil)
        model.dismissQuickLook()
        #expect(model.quickLookURL == nil)
        #expect(FileManager.default.fileExists(atPath: url.path)) // Keep Open With usable after Quick Look closes.
        model.quickLook(entry.id)
        try await waitUntil { !model.isBusy }
        let replacement = try #require(model.quickLookURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: replacement.path))
        await model.stop()
        #expect(!FileManager.default.fileExists(atPath: replacement.path))
        #expect(model.quickLookURL == nil)
    }


    @Test(arguments: ["Tree.zip", "Encrypted.7z", "Encrypted.zip"])
    func directExtractionFinishesOnceAfterWritingOutput(name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let model = ArchiveModel(extractor: engine)
        var passwordRequests = 0
        var completions = 0
        var completionError: String?
        model.onPasswordRequest = {
            passwordRequests += 1
            model.submitPassword(passwordRequests == 1 ? "wrong" : "secret")
        }
        model.onCompletion = { error in
            completions += 1
            completionError = error
            #expect(model.output != nil) // A successful listing alone must not finish the job.
            #expect(!model.isBusy)
        }
        defer { model.onPasswordRequest = nil; model.onCompletion = nil; model.cancel() }
        model.open(try workspace.copy(name), behavior: .extractBeside)
        try await waitUntil { completions > 0 }
        #expect(completions == 1)
        #expect(completionError == nil)
        #expect(passwordRequests == (name == "Tree.zip" ? 0 : 2))
        let output = try #require(model.output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try workspace.names() == [name, output.lastPathComponent].sorted())
        await model.stop()
    }

    @Test(arguments: ["Link.tar", "Broken.zip"])
    func directExtractionReportsFailuresWithoutLeavingOutput(name: String) async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let model = ArchiveModel(extractor: engine)
        var completions = 0
        var completionError: String?
        model.onCompletion = { error in completions += 1; completionError = error }
        model.open(try workspace.copy(name), behavior: .extractBeside)
        try await waitUntil { completions > 0 }
        #expect(completions == 1)
        #expect(completionError != nil)
        #expect(model.output == nil)
        #expect(try workspace.names() == [name])
        await model.stop()
    }

    @Test func cancellingDirectExtractionPasswordFinishesWithoutAnError() async throws {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let model = ArchiveModel(extractor: engine)
        var completions = 0
        model.onPasswordRequest = { model.submitPassword(nil) }
        model.onCompletion = { error in completions += 1; #expect(error == nil) }
        defer { model.onPasswordRequest = nil; model.cancel() }
        model.open(try workspace.copy("Encrypted.7z"), behavior: .extractBeside)
        try await waitUntil { completions > 0 }
        #expect(completions == 1)
        #expect(!model.needsPassword)
        #expect(!model.isBusy)
        #expect(model.output == nil)
        #expect(try workspace.names() == ["Encrypted.7z"])
        await model.stop()
    }

}
