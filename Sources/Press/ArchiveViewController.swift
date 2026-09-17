import QuickLookUI
import SwiftUI

// A hosting controller is part of the window's responder chain, so macOS can
// give it ownership of the shared Quick Look panel just as it does in Finder.
@MainActor
final class ArchiveViewController: NSHostingController<ContentView>, @unchecked Sendable,
                                   @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    private let model: ArchiveModel

    init(model: ArchiveModel, dropArchives: @escaping ([URL]) -> Void, chooseArchives: @escaping () -> Void) {
        self.model = model
        super.init(rootView: ContentView(model: model, dropArchives: dropArchives, chooseArchives: chooseArchives))
        rootView.presentQuickLook = { [weak self] url in self?.presentQuickLook(url) }
    }

    required init?(coder: NSCoder) { fatalError("ArchiveViewController is created in code.") }

    private func presentQuickLook(_ url: URL?) {
        if url != nil {
            guard view.window?.isVisible == true, let panel = QLPreviewPanel.shared() else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.updateController()
            if panel.currentController as AnyObject? === self { panel.reloadData() }
        } else if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
                  panel.currentController as AnyObject? === self {
            panel.orderOut(nil)
        }
    }

    // These older NSObject hooks are not actor-annotated in the SDK. AppKit
    // invokes them synchronously on the main thread through the responder chain.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { model.quickLookURL != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            model.dismissQuickLook()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { model.quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        model.quickLookURL as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 { // Space or Escape
            panel.orderOut(nil)
            model.dismissQuickLook()
            return true
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            view.window?.sendEvent(event)
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { model.dismissQuickLook() }
}
