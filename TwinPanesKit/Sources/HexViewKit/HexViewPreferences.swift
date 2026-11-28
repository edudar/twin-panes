import Foundation

/// Shared display preferences (`HexViewOptions`) synced across hex editors and read-only
/// hex Quick Views, optionally persisted in `UserDefaults`.
@MainActor
public final class HexViewPreferences {
    private static let bytesPerRowKey = "hexView.bytesPerRow"
    private static let groupingKey = "hexView.grouping"
    private static let offsetBaseKey = "hexView.offsetBase"
    private static let textEncodingKey = "hexView.textEncoding"

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (HexViewOptions) -> Void
    }

    private let defaults: UserDefaults?
    private var observers: [Observer] = []

    /// Current display options; setting a different value persists it and notifies observers.
    public var options: HexViewOptions {
        didSet {
            guard options != oldValue else { return }
            save(options)
            observers.removeAll { $0.owner == nil }
            for observer in observers where observer.owner != nil { observer.handler(options) }
        }
    }

    /// Creates a store backed by `defaults` (or in-memory when nil), falling back to
    /// `initial` for missing or invalid stored values.
    public init(defaults: UserDefaults? = nil, initial: HexViewOptions = HexViewOptions()) {
        self.defaults = defaults
        self.options = defaults.map { Self.load(from: $0, fallback: initial) } ?? initial
    }

    /// Calls `handler` on the main actor whenever `options` changes, while `owner` is alive.
    public func observe(
        _ owner: AnyObject, _ handler: @escaping @MainActor (HexViewOptions) -> Void
    ) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    private static func load(
        from defaults: UserDefaults, fallback: HexViewOptions
    ) -> HexViewOptions {
        var loaded = fallback
        if defaults.object(forKey: bytesPerRowKey) != nil {
            let raw = defaults.integer(forKey: bytesPerRowKey)
            if raw == 0 {
                loaded.bytesPerRow = .autoFit
            } else if HexViewOptions.allowedBytesPerRow.contains(raw) {
                loaded.bytesPerRow = .fixed(raw)
            }
        }
        if defaults.object(forKey: groupingKey) != nil {
            let raw = defaults.integer(forKey: groupingKey)
            if HexViewOptions.allowedGrouping.contains(raw) { loaded.grouping = raw }
        }
        if let raw = defaults.string(forKey: offsetBaseKey),
            let base = HexViewOptions.OffsetBase(rawValue: raw)
        {
            loaded.offsetBase = base
        }
        if let raw = defaults.string(forKey: textEncodingKey),
            let encoding = HexViewOptions.TextEncoding(rawValue: raw)
        {
            loaded.textEncoding = encoding
        }
        return loaded
    }

    private func save(_ options: HexViewOptions) {
        guard let defaults else { return }
        let bytesPerRow =
            if case .fixed(let count) = options.bytesPerRow { count } else { 0 }
        defaults.set(bytesPerRow, forKey: Self.bytesPerRowKey)
        defaults.set(options.grouping, forKey: Self.groupingKey)
        defaults.set(options.offsetBase.rawValue, forKey: Self.offsetBaseKey)
        defaults.set(options.textEncoding.rawValue, forKey: Self.textEncodingKey)
    }
}
