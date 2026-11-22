import AppKit

@testable import WorkspaceKit

/// Minimal item for model tests. Views of one `TestSession` share a session key.
@MainActor
final class TestItem: WorkspaceItem {
    let id = ItemID()
    let kind: ItemKind
    let title: String
    let session: TestSession?
    var ownDirty = false
    private(set) var closes = 0
    weak var host: WorkspaceHost?
    var onChange: (() -> Void)?
    lazy var viewController = NSViewController()
    let preferredSlot: SlotID

    init(
        _ title: String, kind: ItemKind = "test", session: TestSession? = nil,
        slot: SlotID = .leftPanel
    ) {
        self.title = title
        self.kind = kind
        self.session = session
        preferredSlot = slot
    }

    var isDirty: Bool { session?.isDirty ?? ownDirty }
    var sessionKey: AnyHashable? { session.map { ObjectIdentifier($0) } }

    func save() async throws {
        if let session {
            if session.failSave { throw CocoaError(.fileWriteUnknown) }
            session.isDirty = false
            session.saves += 1
        } else {
            ownDirty = false
        }
    }

    func willClose() { closes += 1 }

    func discardChanges() {
        if let session {
            session.isDirty = false
            session.discards += 1
        } else {
            ownDirty = false
        }
    }
}

@MainActor
final class TestSession {
    var isDirty = false
    var failSave = false
    var saves = 0
    var discards = 0
}
