import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PressApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        withExtendedLifetime(delegate) { _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var archives: [NSWindow: ArchiveModel] = [:]
    private var closing: Set<NSWindow> = []
    private var settings: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        if archives.isEmpty { _ = makeWindow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) { openArchives(urls) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = currentWindow { window.makeKeyAndOrderFront(nil) }
        else { _ = makeWindow() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let models = Array(archives.values)
        guard models.contains(where: \.isBusy) else { return .terminateNow }
        for model in models { model.cancel() }
        Task {
            for model in models { await model.stop() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = archives[sender], model.isBusy else { return true }
        if closing.insert(sender).inserted {
            Task {
                await model.stop()
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        closing.remove(window)
        if let model = archives.removeValue(forKey: window) {
            Task { await model.stop() }
        }
    }

    private var currentWindow: NSWindow? {
        if let window = NSApp.keyWindow, archives[window] != nil { return window }
        return NSApp.orderedWindows.first { archives[$0] != nil }
    }

    private func makeWindow(beside anchor: NSWindow? = nil) -> NSWindow {
        let model = ArchiveModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Press"
        window.minSize = NSSize(width: 560, height: 410)
        window.tabbingIdentifier = "PressArchives"
        window.tabbingMode = .preferred
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ContentView(model: model,
            openArchives: { [weak self] in self?.openArchives($0) },
            chooseArchives: { [weak self] in self?.chooseArchive() }))
        window.isReleasedWhenClosed = false
        model.window = window
        archives[window] = model
        if let anchor { anchor.addTabbedWindow(window, ordered: .above) }
        else { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func openArchives(_ urls: [URL]) {
        for url in urls {
            if let existing = archives.first(where: { $0.value.source?.standardizedFileURL == url.standardizedFileURL })?.key {
                existing.makeKeyAndOrderFront(nil)
                continue
            }
            let window = archives.first(where: { $0.value.source == nil })?.key ?? makeWindow(beside: currentWindow)
            window.title = url.lastPathComponent
            window.tab.title = url.lastPathComponent
            window.representedURL = url
            archives[window]?.open(url)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "Open archives"
        panel.prompt = "Open"
        // Let the engine detect containers even when their extension is unknown.
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { self?.openArchives(panel.urls) }
        }
        if let window = currentWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    @objc func newWindowForTab(_ sender: Any?) { _ = makeWindow(beside: currentWindow) }
    @objc private func showSettings() {
        if settings == nil { settings = SettingsWindow() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func extractArchive() { if let window = currentWindow { archives[window]?.chooseDestination() } }
    @objc private func reloadArchive() { if let window = currentWindow { archives[window]?.reload() } }

    private func installMenu() {
        let menu = NSMenu()
        func add(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        let app = add("Press")
        app.addItem(withTitle: "About Press", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Press", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Press", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = add("File")
        for (title, action, key) in [("Open Archives…", #selector(chooseArchive), "o"),
                                      ("New Tab", #selector(newWindowForTab(_:)), "t"),
                                      ("Extract…", #selector(extractArchive), "e"),
                                      ("Reload Preview", #selector(reloadArchive), "r")] {
            let item = file.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = add("Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = add("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }
}
