import AppKit
import Darwin
import TwinPanesCore

/// Asks what to do with an item whose name is taken (docs/plans/M6.md, D-d): both items
/// described, a button for each choice that fits, and Apply to All.
@MainActor
public final class ConflictSheet {
    let alert = NSAlert()
    let applyToAll = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
    private let choices: [ConflictChoice]

    public init(_ conflict: Conflict) {
        choices = conflict.choices
        let name = conflict.existing.lastPathComponent
        if conflict.isSameItem {
            alert.messageText = "You're putting “\(name)” where it already is."
            alert.informativeText = "Keep Both makes a copy beside it."
        } else {
            let folder = conflict.existing.deletingLastPathComponent().lastPathComponent
            alert.messageText = "An item named “\(name)” already exists in “\(folder)”."
            alert.informativeText =
                "New: \(Self.describe(conflict.item.source, conflict.item.metadata))\n"
                + "Existing: \(Self.describe(conflict.existing, conflict.existingMetadata))"
        }
        alert.alertStyle = .warning
        for choice in choices {
            let button = alert.addButton(withTitle: Self.title(of: choice))
            if choice == .stop { button.keyEquivalent = "\u{1b}" }
        }
        alert.accessoryView = applyToAll
    }

    /// Shows the sheet on `window` and returns the answer once a button is clicked.
    public func ask(on window: NSWindow) async -> ConflictAnswer {
        let response = await alert.beginSheetModal(for: window)
        return answer(
            forButtonAt: response.rawValue
                - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
    }

    /// The answer a click on the `index`th button gives.
    func answer(forButtonAt index: Int) -> ConflictAnswer {
        // A sheet closed some other way (its window went) stops the operation.
        let choice = choices.indices.contains(index) ? choices[index] : .stop
        return ConflictAnswer(choice, applyToAll: applyToAll.state == .on && choice != .stop)
    }

    private static func title(of choice: ConflictChoice) -> String {
        switch choice {
        case .replace: "Replace"
        case .skip: "Skip"
        case .keepBoth: "Keep Both"
        case .merge: "Merge"
        case .stop: "Stop"
        }
    }

    /// "folder" or "file, 2 KB, modified 24 Nov 2026 at 21:05".
    private static func describe(_ url: URL, _ metadata: FileItemMetadata) -> String {
        let kind =
            switch metadata.kind {
            case .folder: "folder"
            case .symbolicLink: "alias"
            case .file, .other: "file"
            }
        var parts = [kind]
        if metadata.kind == .file {
            parts.append(
                ByteCountFormatter.string(fromByteCount: Int64(metadata.size), countStyle: .file))
        }
        // Two dates read on the main actor while the operation waits on this sheet:
        // too small to move off it. lstat reads a symlink's own date instead of
        // following a dangling or slow target; a date that can't be read is left out.
        var info = stat()
        if lstat(url.path, &info) == 0 {
            let modified = Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            parts.append("modified \(modified.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: ", ")
    }
}
