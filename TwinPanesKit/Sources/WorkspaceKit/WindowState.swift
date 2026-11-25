import Foundation

/// What one item saves to be rebuilt after a relaunch (docs/plans/M5.md, D-c). The
/// payload's format belongs to the item's kind and is versioned by it.
public struct ItemState: Codable, Equatable, Sendable {
    public let kind: ItemKind
    public let version: Int
    public let payload: Data

    public init(kind: ItemKind, version: Int, payload: Data) {
        self.kind = kind
        self.version = version
        self.payload = payload
    }
}

/// One panel's tabs, left to right, and which of them is selected.
public struct PanelState: Codable, Equatable, Sendable {
    public var items: [ItemState]
    public var selectedIndex: Int?
}

/// A tab named by where it sits.
public struct TabPosition: Codable, Equatable, Sendable {
    public var panel: SlotID
    public var index: Int
}

/// A main window's saved tabs (docs/plans/M5.md, D-c), encoded as JSON. Fields added
/// later are optional, so state saved by an older build still decodes.
public struct WindowState: Codable, Equatable, Sendable {
    /// The format this build writes; state with a newer one is refused, never misread.
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public var left: PanelState
    public var right: PanelState
    public var activePanel: SlotID
    public var zoomed: TabPosition?
    /// The left panel's share of the split, 0...1; nil starts the panels as halves.
    public var dividerFraction: Double?
    /// Whether the sidebar was shown, and how wide it was; nil for the defaults.
    public var sidebarShown: Bool?
    public var sidebarWidth: Double?

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

// Outside the struct, so it keeps its memberwise initializer.
extension WindowState {
    /// Throws `WindowStateError.newerVersion` for state written by a newer build, and
    /// the decoder's error for anything that isn't window state.
    public init(decoding data: Data) throws {
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).version
        guard version <= Self.currentVersion else {
            throw WindowStateError.newerVersion(version)
        }
        self = try decoder.decode(Self.self, from: data)
    }
}

extension WindowState {
    /// The key a window's state is kept under in AppKit's restorable state.
    static let restorationKey = "TwinPanes.windowState"

    /// Writes the state into a window's restorable state, for AppKit restoration (D23).
    public func encode(into coder: NSCoder) throws {
        coder.encode(try encoded() as NSData, forKey: Self.restorationKey)
    }

    /// Reads what `encode(into:)` wrote. Throws `WindowStateError.missing` when the
    /// coder holds none, and whatever `init(decoding:)` throws for what it holds.
    public init(restorableStateFrom coder: NSCoder) throws {
        guard let data = coder.decodeObject(of: NSData.self, forKey: Self.restorationKey)
        else { throw WindowStateError.missing }
        try self.init(decoding: data as Data)
    }
}

public enum WindowStateError: Error, Equatable {
    case newerVersion(Int)
    case missing
}

/// Rebuilds items from their saved state: one factory per kind, each with the newest
/// version it reads (docs/plans/M5.md, D-c). The app registers the factories.
@MainActor
public struct ItemRestorer {
    public typealias Factory = (ItemState) -> (any WorkspaceItem)?

    private var factories: [ItemKind: (newestVersion: Int, make: Factory)] = [:]

    public init() {}

    /// `make` returns nil for state it can't use, such as a file that's gone.
    public mutating func register(
        _ kind: ItemKind, newestVersion: Int, make: @escaping Factory
    ) {
        factories[kind] = (newestVersion, make)
    }

    /// The rebuilt item, or nil when the kind is unknown, the version is newer than its
    /// factory reads, or the factory can't use the state.
    public func item(from state: ItemState) -> (any WorkspaceItem)? {
        guard let factory = factories[state.kind], state.version <= factory.newestVersion
        else { return nil }
        return factory.make(state)
    }
}

extension MainFrameLayout {
    /// The tabs to save. Items without `restorableState` are left out, and the
    /// selection and zoom are kept only when they name a saved tab.
    public var savedState: WindowState {
        WindowState(
            left: savedState(of: .leftPanel), right: savedState(of: .rightPanel),
            activePanel: activePanel, zoomed: savedZoom)
    }

    private var savedZoom: TabPosition? {
        guard let zoomedItemID else { return nil }
        for panel in [SlotID.leftPanel, .rightPanel] {
            if let index = savedItemIDs(in: panel).firstIndex(of: zoomedItemID) {
                return TabPosition(panel: panel, index: index)
            }
        }
        return nil
    }

    private func savedItemIDs(in panel: SlotID) -> [ItemID] {
        items(in: panel).filter { $0.restorableState != nil }.map(\.id)
    }

    private func savedState(of panel: SlotID) -> PanelState {
        PanelState(
            items: items(in: panel).compactMap(\.restorableState),
            selectedIndex: selection[panel].flatMap { savedItemIDs(in: panel).firstIndex(of: $0) })
    }

    /// Adds the tabs `state` describes. Tabs the restorer can't rebuild are skipped; a
    /// skipped selection falls back to the panel's first tab and a skipped zoom to
    /// none. Panels left empty get the filler's tab, so a window that restores nothing
    /// opens with the default browsers.
    public func restore(_ state: WindowState, using restorer: ItemRestorer) {
        var zoomed: ItemID?
        for (panel, saved) in [(SlotID.leftPanel, state.left), (.rightPanel, state.right)] {
            var selected: ItemID?
            for (index, itemState) in saved.items.enumerated() {
                guard let item = restorer.item(from: itemState) else { continue }
                insert(item, in: panel, at: items(in: panel).count, select: false)
                if index == saved.selectedIndex { selected = item.id }
                if state.zoomed == TabPosition(panel: panel, index: index) { zoomed = item.id }
            }
            if let first = selected ?? items(in: panel).first?.id { select(first) }
        }
        fillEmptyPanels()
        // Saved state is data from disk: a slot that isn't a panel is ignored.
        if state.activePanel.isPanel { activate(state.activePanel) }
        if let zoomed { toggleZoom(zoomed) }
    }
}
