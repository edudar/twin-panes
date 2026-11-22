import AppKit
import HexViewKit
import TwinPanesCore
import WorkspaceKit

extension ItemKind {
    /// Editor items, in any mode. Bindings in `.item(.editor)` apply to all of them.
    public static let editor: ItemKind = "editor"
}

/// A hex editor tab over one file. Edits go into an `EditBuffer` (M3a); every read the
/// view, search, inspector and Save Selection make goes through its current snapshot.
/// Sessions and saving come in M3b.
@MainActor
public final class HexEditorItem: WorkspaceItem {
    public let id = ItemID()
    public let kind: ItemKind = .editor
    public let preferredSlot: SlotID = .leftPanel
    public let url: URL
    public let source: ByteSource
    /// The edit model over `source`.
    public let buffer: EditBuffer
    public weak var host: WorkspaceHost?
    public var onChange: (() -> Void)?

    /// Keeps sandbox access for as long as the tab is open (PLAN.md §5).
    let scope: SecurityScope?
    lazy var controller = HexEditorViewController(item: self)

    /// Opens `url`. Throws `ByteSourceError` for anything but a readable regular file.
    public init(url: URL, scope: SecurityScope? = nil) throws {
        self.url = url
        self.scope = scope
        let source = try ByteSource(url: url)
        self.source = source
        self.buffer = try EditBuffer(original: source)
    }

    /// The current version, for reading on any thread.
    public var snapshot: EditSnapshot { buffer.snapshot() }

    public var title: String { url.lastPathComponent }
    public var icon: NSImage? { NSWorkspace.shared.icon(forFile: url.path) }
    public var viewController: NSViewController { controller }
    public var preferredFirstResponder: NSView? { controller.hexView }
    public var hexView: HexView { controller.hexView }

    /// Status line text for the current cursor and selection.
    public var statusText: String {
        guard length > 0 else { return "\(title) · empty file · Read-only" }
        let cursor = hexView.selection.cursor
        let range = hexView.selection.range
        var parts = ["Offset \(Self.hex(cursor)) (\(cursor))"]
        if range.count > 1 {
            let last = Self.hex(range.upperBound - 1)
            parts.append("Selected \(range.count) bytes (\(Self.hex(range.lowerBound))…\(last))")
        }
        parts.append("Size \(Self.byteCount(length))")
        parts.append("Read-only")
        return parts.joined(separator: " · ")
    }

    /// The offset Go to Offset means by `text` (decimal, hex or relative to `cursor`,
    /// see `HexOffsetParser`), or nil if it isn't one or lies outside the file.
    func offset(for text: String, cursor: UInt64) -> UInt64? {
        guard let offset = HexOffsetParser.parse(text, current: cursor),
            offset < max(length, 1)
        else { return nil }
        return offset
    }

    func updateStatus() { host?.showStatus(statusText) }

    /// Stops a running search, which would otherwise keep scanning (and keep the file
    /// open) after the tab is gone.
    public func willClose() { controller.cancelSearch() }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    static func byteCount(_ value: UInt64) -> String {
        let short = ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
        return "\(short) (\(value.formatted()) bytes)"
    }
}

extension HexEditorItem: HexViewDataSource {
    public var length: UInt64 { buffer.length }

    public func cachedBytes(_ range: Range<UInt64>) -> Data? { snapshot.cachedBytes(range) }

    public func prefetch(
        _ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void
    ) {
        snapshot.prefetch(range) { error in completion(error) }
    }

    public func read(_ range: Range<UInt64>) throws -> Data { try snapshot.read(range) }

    public func modifiedRanges(in range: Range<UInt64>) -> [Range<UInt64>] {
        snapshot.modifiedRanges(in: range)
    }

    /// Copies through `readSequential` so copying up to 16 MiB never evicts the view's
    /// LRU page cache; large selections read off the main thread while keeping `scope`.
    public func readForCopy(
        _ range: Range<UInt64>, completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        let readExact: @Sendable (EditSnapshot) -> Result<Data, Error> = { source in
            Result {
                let data = try source.readSequential(range)
                guard UInt64(data.count) == range.count else {
                    throw ByteSourceError.truncated(
                        expected: range.upperBound, available: range.lowerBound + UInt64(data.count)
                    )
                }
                return data
            }
        }
        let source = snapshot
        if range.count <= 256 * 1024 {
            completion(readExact(source))
            return
        }
        let scope = self.scope
        Task.detached(priority: .userInitiated) {
            let result = withExtendedLifetime(scope) { readExact(source) }
            await MainActor.run { completion(result) }
        }
    }
}
