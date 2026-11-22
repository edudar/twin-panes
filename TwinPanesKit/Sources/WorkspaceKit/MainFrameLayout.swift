import Foundation

/// The model of one main window: which items sit in which slot, which tab is selected,
/// which panel is active, and what is zoomed (PLAN.md §4.8).
///
/// Pure model, no views. `MainFrameViewController` renders it. Every main window owns
/// its own layout; nothing here assumes a single window (D8).
@MainActor
public final class MainFrameLayout {
    public private(set) var tabs: [SlotID: [any WorkspaceItem]] = [:]
    public private(set) var selection: [SlotID: ItemID] = [:]
    public private(set) var activePanel: SlotID = .leftPanel
    public private(set) var zoomedItemID: ItemID?

    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    // MARK: Queries

    public var allItems: [any WorkspaceItem] {
        SlotID.allCases.flatMap { tabs[$0] ?? [] }
    }

    public func items(in slot: SlotID) -> [any WorkspaceItem] { tabs[slot] ?? [] }

    public func item(_ id: ItemID) -> (any WorkspaceItem)? {
        allItems.first { $0.id == id }
    }

    public func slot(of id: ItemID) -> SlotID? {
        SlotID.allCases.first { slot in items(in: slot).contains { $0.id == id } }
    }

    public func selectedItem(in slot: SlotID) -> (any WorkspaceItem)? {
        guard let id = selection[slot] else { return nil }
        return items(in: slot).first { $0.id == id }
    }

    /// The selected item of the active panel: what panel-level commands act on.
    public var focusedPanelItem: (any WorkspaceItem)? { selectedItem(in: activePanel) }

    public var zoomedItem: (any WorkspaceItem)? { zoomedItemID.flatMap(item) }

    // MARK: Mutations

    /// Adds `item` to `slot` (default: the item's preferred slot) at `index`
    /// (default: after the selected tab).
    public func insert(
        _ item: any WorkspaceItem, in slot: SlotID? = nil, at index: Int? = nil,
        select: Bool = true
    ) {
        precondition(self.item(item.id) == nil, "item \(item.id) is already in this layout")
        let slot = slot ?? item.preferredSlot
        var list = items(in: slot)
        let defaultIndex =
            selection[slot].flatMap { id in list.firstIndex { $0.id == id }.map { $0 + 1 } }
            ?? list.count
        list.insert(item, at: min(max(index ?? defaultIndex, 0), list.count))
        tabs[slot] = list
        if select || selection[slot] == nil { selection[slot] = item.id }
        if select && slot.isPanel { activePanel = slot }
        notify()
    }

    /// Removes the item and returns it. The neighbouring tab becomes selected; zoom is
    /// cleared if the zoomed item goes away.
    @discardableResult
    public func remove(_ id: ItemID) -> (any WorkspaceItem)? {
        guard let slot = slot(of: id), var list = tabs[slot],
            let index = list.firstIndex(where: { $0.id == id })
        else { return nil }
        let removed = list.remove(at: index)
        tabs[slot] = list
        if selection[slot] == id {
            selection[slot] = list.isEmpty ? nil : list[min(index, list.count - 1)].id
        }
        if zoomedItemID == id { zoomedItemID = nil }
        notify()
        return removed
    }

    /// Moves an item to another slot or position without recreating it.
    public func move(_ id: ItemID, to destination: SlotID, at index: Int? = nil) {
        guard let source = slot(of: id), var sourceList = tabs[source],
            let oldIndex = sourceList.firstIndex(where: { $0.id == id })
        else { return }
        let item = sourceList.remove(at: oldIndex)
        if source == destination {
            let target = min(max(index ?? sourceList.count, 0), sourceList.count)
            sourceList.insert(item, at: target)
            tabs[source] = sourceList
        } else {
            tabs[source] = sourceList
            if selection[source] == id {
                selection[source] =
                    sourceList.isEmpty ? nil : sourceList[min(oldIndex, sourceList.count - 1)].id
            }
            var destList = items(in: destination)
            let defaultIndex =
                selection[destination].flatMap { sel in
                    destList.firstIndex { $0.id == sel }.map { $0 + 1 }
                } ?? destList.count
            destList.insert(item, at: min(max(index ?? defaultIndex, 0), destList.count))
            tabs[destination] = destList
        }
        selection[destination] = id
        if destination.isPanel { activePanel = destination }
        notify()
    }

    public func select(_ id: ItemID) {
        guard let slot = slot(of: id) else { return }
        selection[slot] = id
        if slot.isPanel { activePanel = slot }
        notify()
    }

    /// Selects the tab `offset` positions away in the active panel, wrapping around.
    public func selectAdjacentTab(_ offset: Int) {
        let list = items(in: activePanel)
        guard !list.isEmpty, let current = focusedPanelItem,
            let index = list.firstIndex(where: { $0.id == current.id })
        else { return }
        let next = ((index + offset) % list.count + list.count) % list.count
        select(list[next].id)
    }

    public func activate(_ panel: SlotID) {
        precondition(panel.isPanel)
        activePanel = panel
        notify()
    }

    /// Zooms `id` (default: the focused panel item) to fill the frame, or un-zooms if it
    /// is already zoomed.
    public func toggleZoom(_ id: ItemID? = nil) {
        if zoomedItemID != nil {
            zoomedItemID = nil
        } else if let target = id ?? focusedPanelItem?.id, item(target) != nil {
            zoomedItemID = target
        }
        notify()
    }

    public func exitZoom() {
        guard zoomedItemID != nil else { return }
        zoomedItemID = nil
        notify()
    }

    // MARK: Observation

    /// Registers a change handler. Keep the returned token to stay subscribed.
    public func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        let key = UUID()
        observers[key] = handler
        return ObservationToken { [weak self] in
            Task { @MainActor in self?.observers[key] = nil }
        }
    }

    private func notify() {
        for handler in observers.values { handler() }
    }
}

/// Unsubscribes when released.
public final class ObservationToken: Sendable {
    private let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
