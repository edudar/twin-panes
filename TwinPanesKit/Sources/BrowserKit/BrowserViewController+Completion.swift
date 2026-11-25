import AppKit
import TwinPanesCore

/// Tab in the path field completes the path the way a shell does (PLAN.md §4.7;
/// docs/plans/M5.md, D-e).
extension BrowserViewController {
    /// Completes as far as the folder's matching names agree: at once when the names are
    /// read, else when they arrive, provided the text hasn't changed meanwhile. A Tab that
    /// completes nothing more lists the first 500 matches. Returns true: Tab never moves
    /// focus out of the field.
    func completePath(in textView: NSTextView) -> Bool {
        pendingCompletion?.cancel()
        pendingCompletion = nil
        let text = textView.string
        guard let names = completionNames,
            let query = PathCompletion.query(for: text, home: DirectoryReader.realHomeDirectory)
        else {
            NSSound.beep()
            return true
        }
        pendingCompletion = Task { [weak self, weak textView] in
            let completion = await Self.complete(query, among: names)
            guard !Task.isCancelled, let completion, let self, self.isEditingPath, let textView,
                self.pathField.currentEditor() === textView, textView.string == text
            else {
                if !Task.isCancelled { self?.pendingCompletion = nil }
                return
            }
            self.pendingCompletion = nil
            apply(completion, to: textView, typed: text)
        }
        return true
    }

    private func apply(_ completion: PathCompletion, to textView: NSTextView, typed: String) {
        if completion.completedText != typed {
            let whole = NSRange(location: 0, length: (typed as NSString).length)
            textView.insertText(completion.completedText, replacementRange: whole)
        } else if completion.matches.count > 1 {
            showCompletionList(Array(completion.matchTexts.prefix(Self.listedMatchLimit)), textView)
        } else {
            NSSound.beep()
        }
    }

    /// The whole texts `typed`'s matches complete to, as the second Tab lists them; empty
    /// when it isn't a path to complete or its folder can't be read.
    func listedMatchTexts(for typed: String) async -> [String] {
        guard let names = completionNames,
            let query = PathCompletion.query(for: typed, home: DirectoryReader.realHomeDirectory),
            let completion = await Self.complete(query, among: names)
        else { return [] }
        return Array(completion.matchTexts.prefix(Self.listedMatchLimit))
    }

    /// Reads `query`'s folder and matches its names; nil when the folder can't be read or
    /// the task was cancelled first. Matching 100k names takes tens of milliseconds: off
    /// the main actor too.
    private static func complete(
        _ query: PathCompletion.Query, among names: CompletionNames
    ) async -> PathCompletion? {
        guard let found = await names.names(in: query.folder), !Task.isCancelled else {
            return nil
        }
        return await Task.detached { PathCompletion(query: query, names: found) }.value
    }

    /// More would only make a list nobody scrolls, built on every second Tab.
    private static let listedMatchLimit = 500
}
