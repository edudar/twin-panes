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

    private let filler: PanelFiller
    private var observers: [UUID: () -> Void] = [:]

    /// The layout starts empty; `fillEmptyPanels()` gives it its first tabs.
    public init(filler: PanelFiller) {
        self.filler = filler
    }

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

    /// Whether `remove` would take the item out. A panel's only tab can't go when it is
    /// of the filler's kind, since the filler would only put the same kind back
    /// (docs/plans/M5.md, D-a).
    public func canRemove(_ id: ItemID) -> Bool {
        guard let slot = slot(of: id) else { return false }
        guard slot.isPanel else { return true }
        let list = items(in: slot)
        return list.count > 1 || list.first?.kind != filler.kind
    }

    /// Whether `move` would take the item to `destination`: always within its own slot,
    /// and out of a panel under the same rule as `canRemove`.
    public func canMove(_ id: ItemID, to destination: SlotID) -> Bool {
        slot(of: id) == destination || canRemove(id)
    }

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

    /// Gives each empty panel a tab from the filler, the left panel first, so the right
    /// one's filler can start where the left one does.
    public func fillEmptyPanels() {
        for panel in [SlotID.leftPanel, .rightPanel] where items(in: panel).isEmpty {
            fill(panel)
        }
        notify()
    }

    /// Puts the filler's tab into an empty panel, selected, without notifying.
    private func fill(_ panel: SlotID) {
        let item = filler.make(panel, self)
        tabs[panel] = [item]
        selection[panel] = item.id
    }

    /// Removes the item and returns it, or returns nil when `canRemove` says no. The
    /// neighbouring tab becomes selected, a panel left empty gets a tab from the filler,
    /// and zoom is cleared if the zoomed item goes away.
    @discardableResult
    public func remove(_ id: ItemID) -> (any WorkspaceItem)? {
        guard canRemove(id), let slot = slot(of: id), var list = tabs[slot],
            let index = list.firstIndex(where: { $0.id == id })
        else { return nil }
        let removed = list.remove(at: index)
        tabs[slot] = list
        if selection[slot] == id {
            selection[slot] = list.isEmpty ? nil : list[min(index, list.count - 1)].id
        }
        if slot.isPanel && list.isEmpty { fill(slot) }
        if zoomedItemID == id { zoomedItemID = nil }
        notify()
        return removed
    }

    /// Moves an item to another slot or position without recreating it, unless
    /// `canMove` says no. A panel left empty gets a tab from the filler.
    public func move(_ id: ItemID, to destination: SlotID, at index: Int? = nil) {
        guard canMove(id, to: destination), let source = slot(of: id),
            var sourceList = tabs[source],
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
            if source.isPanel && sourceList.isEmpty { fill(source) }
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

/// Makes the tab a panel gets when it would otherwise be empty: the app's browser
/// (docs/plans/M5.md, D-a). WorkspaceKit doesn't know browsers, so the app supplies it.
@MainActor
public struct PanelFiller {
    /// The kind of item `make` returns.
    public let kind: ItemKind
    /// Makes the tab for `panel` of `layout`, which may look at the other panel.
    public let make: (_ panel: SlotID, _ layout: MainFrameLayout) -> any WorkspaceItem

    public init(
        kind: ItemKind,
        make: @escaping (_ panel: SlotID, _ layout: MainFrameLayout) -> any WorkspaceItem
    ) {
        self.kind = kind
        self.make = make
    }
}

/// Unsubscribes when released.
public final class ObservationToken: Sendable {
    private let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
