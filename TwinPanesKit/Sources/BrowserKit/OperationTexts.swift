import Foundation
import TwinPanesCore

/// What a progress row says about an operation (docs/plans/M6.md, D-e).
@MainActor
enum OperationTexts {
    /// "Copying “a.txt” to “Backup”", "Couldn't copy 2 items", "Copied 3 items".
    static func title(of operation: QueuedOperation) -> String {
        let (doing, did, what, destination) = words(for: operation.request)
        let place = destination.map { " to “\($0.lastPathComponent)”" } ?? ""
        guard let result = operation.result else { return "\(doing) \(what)\(place)" }
        let failed = result.failures.count
        if failed > 0 {
            return "Couldn't \(lowercasedVerb(did)) \(count(failed))\(trashSuffix(operation))"
        }
        if result.refusal != nil { return "Couldn't \(lowercasedVerb(did)) \(what)" }
        if result.wasCancelled { return "Stopped \(doing.lowercased()) \(what)" }
        return "\(did) \(what)\(place)"
    }

    /// "Queued", "Waiting for your answer", "1.2 MB of 5 MB · 30 of 120 items".
    static func detail(of operation: QueuedOperation) -> String {
        if let result = operation.result {
            if !result.failures.isEmpty { return "\(count(result.failures.count)) failed" }
            if result.refusal != nil { return "Refused" }
            if result.wasCancelled { return "Stopped" }
            return "Done"
        }
        if case .waitingForAnswer = operation.state { return "Waiting for your answer" }
        if operation.isPaused { return "Paused" }
        if case .queued = operation.state { return "Queued" }
        let progress = operation.progress
        if progress.isDownloading, let item = progress.currentItem {
            return "Downloading “\((item as NSString).lastPathComponent)” from iCloud"
        }
        let items = "\(progress.itemsDone) of \(progress.itemsTotal) items"
        guard progress.bytesTotal > 0 else { return items }
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(progress.bytesDone), countStyle: .file)
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(progress.bytesTotal), countStyle: .file)
        return "\(bytes) of \(total) · \(items)"
    }

    private static func words(
        for request: OperationRequest
    )
        -> (doing: String, did: String, what: String, destination: URL?)
    {
        switch request {
        case .copy(let items, let destination):
            ("Copying", "Copied", describe(items), destination)
        case .move(let items, let destination):
            ("Moving", "Moved", describe(items), destination)
        case .trash(let items): ("Moving", "Moved", describe(items) + " to the Trash", nil)
        case .delete(let items): ("Deleting", "Deleted", describe(items), nil)
        case .putBack(let items): ("Putting back", "Put back", describe(items.map(\.from)), nil)
        case .rename(let item, let name):
            ("Renaming", "Renamed", "“\(item.lastPathComponent)” to “\(name)”", nil)
        case .makeFolder(let name, _): ("Making", "Made", "folder “\(name)”", nil)
        }
    }

    private static func describe(_ items: [URL]) -> String {
        items.count == 1 ? "“\(items[0].lastPathComponent)”" : count(items.count)
    }

    private static func count(_ items: Int) -> String { items == 1 ? "1 item" : "\(items) items" }

    private static func lowercasedVerb(_ did: String) -> String {
        switch did {
        case "Copied": "copy"
        case "Moved": "move"
        case "Deleted": "delete"
        case "Put back": "put back"
        case "Renamed": "rename"
        default: "make"
        }
    }

    private static func trashSuffix(_ operation: QueuedOperation) -> String {
        if case .trash = operation.request { return " to the Trash" }
        return ""
    }
}
