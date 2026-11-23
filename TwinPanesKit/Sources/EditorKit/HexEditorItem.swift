import AppKit
import HexViewKit
import TwinPanesCore
import WorkspaceKit

extension ItemKind {
    /// Editor items, in any mode. Bindings in `.item(.editor)` apply to all of them.
    public static let editor: ItemKind = "editor"
}

/// A hex editor tab over one file's `EditorSession` (docs/plans/M3b.md, D-a). The session
/// owns the bytes, the undo history and the saved version; the tab keeps presentation
/// (selection, typing burst, find, view options) and follows the session's changes.
/// Every read the view, search, inspector and Save Selection make goes through the
/// session's current snapshot.
@MainActor
public final class HexEditorItem: WorkspaceItem {
    public let id = ItemID()
    public let kind: ItemKind = .editor
    public let preferredSlot: SlotID = .leftPanel
    public let session: EditorSession
    public weak var host: WorkspaceHost?
    public var onChange: (() -> Void)?
    /// Called after Save As moved the session to another file (the app notes it as a
    /// recent file).
    public var didSaveAs: ((URL) -> Void)?

    public var url: URL { session.url }
    public var source: ByteSource { session.buffer.original }
    /// The edit model over `source`.
    public var buffer: EditBuffer { session.buffer }
    /// Keeps sandbox access while the session lives (PLAN.md §5).
    var scope: SecurityScope? { session.scope }
    /// Views of one session share it, so the close workflow asks once per session.
    public var sessionKey: AnyHashable? { session.id }

    /// The last typed byte, for coalescing a typing burst into one undo step.
    var lastTyping: Typing?
    struct Typing {
        let column: HexLayout.Column
        let cursorAfter: UInt64
        let time: ContinuousClock.Instant
    }

    lazy var controller = HexEditorViewController(item: self)

    /// Opens `url` in a new session. Throws `ByteSourceError` for anything but a readable
    /// regular file.
    public convenience init(url: URL, scope: SecurityScope? = nil) throws {
        self.init(session: try EditorSession(url: url, scope: scope))
    }

    /// A tab showing `session`.
    public init(session: EditorSession) {
        self.session = session
        session.observe(self) { [weak self] change in self?.sessionChanged(change) }
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
        guard length > 0 else { return "\(title) · empty file" }
        let cursor = hexView.selection.cursor
        let range = hexView.selection.range
        var parts = ["Offset \(Self.hex(cursor)) (\(cursor))"]
        if range.count > 1 {
            let last = Self.hex(range.upperBound - 1)
            parts.append("Selected \(range.count) bytes (\(Self.hex(range.lowerBound))…\(last))")
        }
        parts.append("Size \(Self.byteCount(length))")
        if case .readOnly(let reason) = session.access {
            parts.append("Read-only: \(reason)")
        } else if session.isSaving {
            parts.append("Saving…")
        } else if isDirty {
            parts.append(session.wasRecovered ? "Recovered unsaved changes" : "Modified")
        }
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
    /// open) after the tab is gone, and closes the session.
    public func willClose() {
        controller.cancelSearch()
        // One tab per session for now (the registry brings an open file's tab forward),
        // so this tab closing ends the session: its folder goes (docs/plans/M3c.md).
        session.close()
    }

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
