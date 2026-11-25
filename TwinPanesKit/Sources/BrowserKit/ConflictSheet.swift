import AppKit
import TwinPanesCore

/// Asks what to do with an item whose name is taken (docs/plans/M6.md, D-d): both items
/// described, a button for each choice that fits, and Apply to All.
@MainActor
final class ConflictSheet {
    let alert = NSAlert()
    let applyToAll = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
    private let choices: [ConflictChoice]

    init(_ conflict: Conflict) {
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
        for choice in choices { alert.addButton(withTitle: Self.title(of: choice)) }
        alert.accessoryView = applyToAll
    }

    /// Shows the sheet on `window` and returns the answer once a button is clicked.
    func ask(on window: NSWindow) async -> ConflictAnswer {
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
        // too small to move off it. A date that can't be read is left out.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let modified {
            parts.append("modified \(modified.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: ", ")
    }
}
