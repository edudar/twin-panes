import AppKit
import BrowserKit
import EditorKit
import TwinPanesCore
import WorkspaceKit

/// Preview pane and Quick View wiring for `AppDelegate` (`docs/plans/M7.md`, D-d, D-e).
extension AppDelegate {
    /// Attaches the trailing preview pane and wires its visibility and teardown callbacks.
    func attachPreviewPane(to controller: MainWindowController) {
        let preview = PreviewPaneViewController()
        let frame = controller.frameController
        frame.onPreviewVisibilityChange = { [weak self, weak preview, weak controller] shown in
            if shown {
                preview?.setActive(true)
                if let controller { self?.updatePreviewPane(in: controller) }
            } else {
                preview?.setActive(false)
            }
        }
        frame.previewPane = preview
        preview.setActive(frame.isPreviewPaneShown)
        frame.onWillClose = { [weak preview, weak self, weak controller] in
            preview?.tearDown()
            if let controller { self?.dropQuickViewSources(in: controller) }
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
        let scope = browser.needsAccess ? nil : browser.activeScope
        if controller.frameController.isPreviewPaneShown,
            (controller.layout.zoomedItem ?? controller.layout.focusedPanelItem)?.id == browser.id
        {
            let selection: ListingSelection =
                browser.needsAccess ? .none : browser.currentSelection
            previewController(in: controller)?.show(selection: selection, scope: scope)
        }
        let entry = browser.needsAccess ? nil : browser.selectedEntry
        for item in controller.layout.allItems {
            guard let quickView = item as? QuickViewItem,
                quickView.isFollowing, !quickView.isPinned,
                quickViewSources[quickView.id] == browser.id
            else { continue }
            quickView.retarget(to: entry, scope: scope)
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
            quickView.show(entry, scope: browser.activeScope)
            controller.layout.insertInBackground(quickView, in: targetPanel)
        case .samePanel:
            let quickView = makeQuickView(isFollowing: false, in: controller)
            quickView.show(entry, scope: browser.activeScope)
            controller.layout.insert(quickView, in: sourceSlot)
        }
    }

    func updatePreviewPane(in controller: MainWindowController) {
        guard controller.frameController.isPreviewPaneShown,
            let preview = previewController(in: controller)
        else { return }
        let active = controller.layout.zoomedItem ?? controller.layout.focusedPanelItem
        if let browser = active as? BrowserItem {
            preview.show(
                selection: browser.needsAccess ? .none : browser.currentSelection,
                scope: browser.needsAccess ? nil : browser.activeScope)
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
        weak var created: QuickViewItem?
        let item = QuickViewItem(
            viewerFactory: viewerFactory, sessions: sessions, isFollowing: isFollowing
        ) { [weak self, weak controller] url, scope in
            let slot = created.flatMap { controller?.layout.slot(of: $0.id) }
            self?.openFile(url, scope: scope, in: controller, slot: slot)
        }
        created = item
        return item
    }

    private func followingQuickView(
        in panel: SlotID, of controller: MainWindowController, from browserID: ItemID
    ) -> QuickViewItem? {
        controller.layout.items(in: panel).lazy
            .compactMap { $0 as? QuickViewItem }
            .first { $0.isFollowing && !$0.isPinned && quickViewSources[$0.id] == browserID }
    }

    /// Permanently detaches any following Quick View tab moved into its source browser's
    /// panel, or whose source browser was closed (docs/plans/M7.md, D-e), and prunes closed
    /// Quick View entries.
    func pinMovedQuickViews(in controller: MainWindowController) {
        let liveIDs = Set(workspace.allItems.map(\.id))
        quickViewSources = quickViewSources.filter { liveIDs.contains($0.key) }
        for item in controller.layout.allItems {
            guard let quickView = item as? QuickViewItem,
                quickView.isFollowing,
                let sourceID = quickViewSources[quickView.id]
            else { continue }
            let quickViewSlot = controller.layout.slot(of: quickView.id)
            let sourceSlot = controller.layout.slot(of: sourceID)
            if sourceSlot == nil || quickViewSlot == sourceSlot {
                quickView.detachFromSource()
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
