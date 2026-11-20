import Foundation

/// App-wide list of main-frame layouts, one per main window (D8). Gives the close
/// workflow its view of "every item open anywhere".
@MainActor
public final class WorkspaceRegistry {
    private var layouts: [ObjectIdentifier: WeakLayout] = [:]

    public init() {}

    public func register(_ layout: MainFrameLayout) {
        layouts[ObjectIdentifier(layout)] = WeakLayout(layout: layout)
    }

    public func unregister(_ layout: MainFrameLayout) {
        layouts[ObjectIdentifier(layout)] = nil
    }

    public var allLayouts: [MainFrameLayout] { layouts.values.compactMap(\.layout) }

    public var allItems: [any WorkspaceItem] { allLayouts.flatMap(\.allItems) }

    /// The layout currently hosting `id`, if any.
    public func layout(containing id: ItemID) -> MainFrameLayout? {
        allLayouts.first { $0.item(id) != nil }
    }

    private struct WeakLayout {
        weak var layout: MainFrameLayout?
    }
}
