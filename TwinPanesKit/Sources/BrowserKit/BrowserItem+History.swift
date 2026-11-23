import AppKit
import TwinPanesCore

/// A folder in a tab's back/forward history, with the entry that was selected there.
struct HistoryEntry: Equatable {
    let folder: URL
    let selected: String?
}

/// Back and forward (docs/plans/M4.md, D-d). Every navigation to another folder pushes
/// where the tab was; going back or forward moves between the stacks without recording.
/// A folder that has since gone away is skipped. Coming back to a folder selects what
/// was selected there, or else the subfolder you're coming back from.
extension BrowserItem {
    var here: HistoryEntry { HistoryEntry(folder: folder, selected: controller.selectedName) }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public func goBack() { step(from: \.backStack, to: \.forwardStack) }
    public func goForward() { step(from: \.forwardStack, to: \.backStack) }

    private func step(
        from source: ReferenceWritableKeyPath<BrowserItem, [HistoryEntry]>,
        to destination: ReferenceWritableKeyPath<BrowserItem, [HistoryEntry]>
    ) {
        let leaving = here
        var skipped: [String] = []
        while let entry = self[keyPath: source].popLast() {
            // Nothing was selected there: select the folder you're coming back from.
            let cameFrom =
                leaving.folder.deletingLastPathComponent().path == entry.folder.path
                ? leaving.folder.lastPathComponent : nil
            let selecting = entry.selected ?? cameFrom
            if navigate(to: entry.folder, selecting: selecting, recording: false, quietly: true) {
                self[keyPath: destination].append(leaving)
                if !skipped.isEmpty {
                    host?.showStatus("Skipped \(skipped.joined(separator: ", ")): no longer there")
                }
                return
            }
            skipped.append("“\(entry.folder.lastPathComponent)”")
        }
        NSSound.beep()
    }
}
