import AppKit
import HexViewKit
import TwinPanesCore
import WorkspaceKit

extension ItemKind {
    /// Editor items, in any mode. Bindings in `.item(.editor)` apply to all of them.
    public static let editor: ItemKind = "editor"
}

/// A read-only hex editor tab over one file (M1). Editing, sessions and saving come
/// with the piece table in M3; until then the item owns its `ByteSource` directly.
@MainActor
public final class HexEditorItem: WorkspaceItem {
    public let id = ItemID()
    public let kind: ItemKind = .editor
    public let preferredSlot: SlotID = .leftPanel
    public let url: URL
    public let source: ByteSource
    public weak var host: WorkspaceHost?
    public var onChange: (() -> Void)?

    /// Keeps sandbox access for as long as the tab is open (PLAN.md §5).
    private let scope: SecurityScope?
    private lazy var controller = HexEditorViewController(item: self)

    /// Opens `url`. Throws `ByteSourceError` for anything but a readable regular file.
    public init(url: URL, scope: SecurityScope? = nil) throws {
        self.url = url
        self.scope = scope
        self.source = try ByteSource(url: url)
    }

    public var title: String { url.lastPathComponent }
    public var icon: NSImage? { NSWorkspace.shared.icon(forFile: url.path) }
    public var viewController: NSViewController { controller }
    public var preferredFirstResponder: NSView? { controller.hexView }
    public var hexView: HexView { controller.hexView }

    /// Status line text for the current cursor and selection.
    public var statusText: String {
        guard source.length > 0 else { return "\(title) · empty file · Read-only" }
        let cursor = hexView.selection.cursor
        let range = hexView.selection.range
        var parts = ["Offset \(Self.hex(cursor)) (\(cursor))"]
        if range.count > 1 {
            let last = Self.hex(range.upperBound - 1)
            parts.append("Selected \(range.count) bytes (\(Self.hex(range.lowerBound))…\(last))")
        }
        parts.append("Size \(Self.byteCount(source.length))")
        parts.append("Read-only")
        return parts.joined(separator: " · ")
    }

    func updateStatus() { host?.showStatus(statusText) }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    static func byteCount(_ value: UInt64) -> String {
        let short = ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
        return "\(short) (\(value.formatted()) bytes)"
    }
}

extension HexEditorItem: HexViewDataSource {
    public var length: UInt64 { source.length }

    public func cachedBytes(_ range: Range<UInt64>) -> Data? { source.cachedBytes(range) }

    public func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor () -> Void) {
        source.prefetch(range) { [weak self] error in
            if let error { self?.host?.showStatus(error.description) }
            completion()
        }
    }

    public func read(_ range: Range<UInt64>) throws -> Data { try source.read(range) }
}
