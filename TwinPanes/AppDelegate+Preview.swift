import AppKit
import BrowserKit
import EditorKit
import TwinPanesCore
import WorkspaceKit

/// Preview pane and Quick View wiring for `AppDelegate` (`docs/plans/M7.md`, D-d, D-e).
extension AppDelegate {
    /// Attaches the trailing preview pane and wires layout updates for auto-pinning
    /// following Quick View tabs and refreshing the preview pane.
    func attachPreviewPane(to controller: MainWindowController) {
        let preview = PreviewPaneViewController(viewerFactory: viewerFactory, sessions: sessions)
        let frame = controller.frameController
        frame.onPreviewVisibilityChange = { [weak self, weak preview, weak controller] shown in
            preview?.setActive(shown)
            if shown, let controller { self?.updatePreviewPane(in: controller) }
        }
        frame.previewPane = preview
        preview.setActive(frame.isPreviewPaneShown)
        frame.onWillClose = { [weak preview, weak self, weak controller] in
            preview?.tearDown()
            if let controller { self?.dropQuickViewSources(in: controller) }
        }
        frame.onUpdate = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let active = controller.layout.zoomedItem ?? controller.layout.focusedPanelItem
            (controller.frameController.sidebar as? SidebarViewController)?.highlight(
                (active as? BrowserItem)?.folder)
            self.pinMovedQuickViews(in: controller)
            self.updatePreviewPane(in: controller)
        }
    }

    func configureBrowser(_ browser: BrowserItem) {
        browser.fileCommands = fileOperations
        browser.onSelectionChange = { [weak self] browser in
            self?.browserSelectionChanged(browser)
        }
        browser.viewFile = { [weak self] browser, placement in
            self?.openQuickView(from: browser, placement: placement)
        }
    }

    func browserSelectionChanged(_ browser: BrowserItem) {
        guard let controller = controller(containing: browser.id) else { return }
        if controller.frameController.isPreviewPaneShown,
            (controller.layout.zoomedItem ?? controller.layout.focusedPanelItem)?.id == browser.id
        {
            previewController(in: controller)?.show(
                entries: browser.selectedEntries, scope: browser.activeScope)
        }
        for item in controller.layout.allItems {
            guard let quickView = item as? QuickViewItem,
                quickView.isFollowing, !quickView.isPinned,
                quickViewSources[quickView.id] == browser.id
            else { continue }
            quickView.retarget(to: browser.selectedEntry, scope: browser.activeScope)
        }
    }

    func openQuickView(from browser: BrowserItem, placement: QuickViewPlacement) {
        guard let controller = controller(containing: browser.id),
            let sourceSlot = controller.layout.slot(of: browser.id),
            let entry = browser.selectedEntry
        else { return NSSound.beep() }
        if controller.layout.zoomedItem != nil { controller.layout.exitZoom() }

        switch placement {
        case .oppositePanel:
            guard let targetPanel = sourceSlot.otherPanel else { return }
            if let existing = followingQuickView(in: targetPanel, of: controller, from: browser.id)
            {
                if controller.layout.selectedItem(in: targetPanel)?.id == existing.id {
                    existing.willClose()
                    controller.layout.remove(existing.id)
                    quickViewSources.removeValue(forKey: existing.id)
                    return
                }
                existing.show(entry, scope: browser.activeScope)
                controller.layout.selectInBackground(existing.id)
                return
            }
            let quickView = makeQuickView(isFollowing: true, in: controller)
            quickViewSources[quickView.id] = browser.id
            controller.layout.insertInBackground(quickView, in: targetPanel)
            quickView.show(entry, scope: browser.activeScope)
        case .samePanel:
            let quickView = makeQuickView(isFollowing: false, in: controller)
            controller.layout.insert(quickView, in: sourceSlot)
            quickView.show(entry, scope: browser.activeScope)
        }
    }

    func updatePreviewPane(in controller: MainWindowController) {
        guard controller.frameController.isPreviewPaneShown,
            let preview = previewController(in: controller)
        else { return }
        let active = controller.layout.zoomedItem ?? controller.layout.focusedPanelItem
        if let browser = active as? BrowserItem {
            preview.show(entries: browser.selectedEntries, scope: browser.activeScope)
        } else if let editor = active as? HexEditorItem {
            preview.show(file: editor.url, scope: editor.session.scope)
        } else if let quickView = active as? QuickViewItem {
            let scope = quickView.currentURL.flatMap { folderGrants.scope(covering: $0) }
            preview.show(file: quickView.currentURL, scope: scope)
        } else {
            preview.show(file: nil, scope: nil)
        }
    }

    private func previewController(
        in controller: MainWindowController
    ) -> PreviewPaneViewController? {
        controller.frameController.previewPane as? PreviewPaneViewController
    }

    private func makeQuickView(
        isFollowing: Bool, in controller: MainWindowController
    ) -> QuickViewItem {
        QuickViewItem(viewerFactory: viewerFactory, sessions: sessions, isFollowing: isFollowing) {
            [weak self, weak controller] url, scope in
            self?.openFile(url, scope: scope, in: controller)
        }
    }

    private func followingQuickView(
        in panel: SlotID, of controller: MainWindowController, from browserID: ItemID
    ) -> QuickViewItem? {
        controller.layout.items(in: panel).lazy
            .compactMap { $0 as? QuickViewItem }
            .first { $0.isFollowing && !$0.isPinned && quickViewSources[$0.id] == browserID }
    }

    /// Pins any following Quick View tab moved into its source browser's panel, or whose
    /// source browser was closed (docs/plans/M7.md, D-e).
    private func pinMovedQuickViews(in controller: MainWindowController) {
        for item in controller.layout.allItems {
            guard let quickView = item as? QuickViewItem,
                quickView.isFollowing, !quickView.isPinned,
                let sourceID = quickViewSources[quickView.id]
            else { continue }
            let quickViewSlot = controller.layout.slot(of: quickView.id)
            let sourceSlot = controller.layout.slot(of: sourceID)
            if sourceSlot == nil || quickViewSlot == sourceSlot {
                quickView.pin()
                quickViewSources.removeValue(forKey: quickView.id)
            }
        }
    }

    private func dropQuickViewSources(in controller: MainWindowController) {
        for item in controller.layout.allItems {
            quickViewSources.removeValue(forKey: item.id)
        }
    }
}
