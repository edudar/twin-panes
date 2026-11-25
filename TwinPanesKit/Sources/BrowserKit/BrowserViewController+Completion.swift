import AppKit
import TwinPanesCore

/// Tab in the path field completes the path the way a shell does (PLAN.md §4.7;
/// docs/plans/M5.md, D-e).
extension BrowserViewController {
    /// Completes as far as the folder's matching names agree: at once when the names are
    /// read, else when they arrive, provided the text hasn't changed meanwhile. A Tab that
    /// completes nothing more opens AppKit's list of the matches. Returns true: Tab never
    /// moves focus out of the field.
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
            guard let found = await names.names(in: query.folder) else {
                if !Task.isCancelled { self?.pendingCompletion = nil }
                return
            }
            if Task.isCancelled { return }
            // Matching 100k names takes tens of milliseconds: off the main actor too.
            let completion = await Task.detached { PathCompletion(query: query, names: found) }
                .value
            guard !Task.isCancelled, let self, self.isEditingPath, let textView,
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
        lastCompletion = completion
        if completion.completedText != typed {
            let whole = NSRange(location: 0, length: (typed as NSString).length)
            textView.insertText(completion.completedText, replacementRange: whole)
        } else if completion.matches.count > 1 {
            textView.selectedRange = NSRange(location: (typed as NSString).length, length: 0)
            showCompletionList(textView)
        } else {
            NSSound.beep()
        }
    }

    /// AppKit's completion list: each match as a replacement for `charRange`, AppKit's
    /// idea of the last word, which stops at spaces and `/` as well.
    func control(
        _ control: NSControl, textView: NSTextView, completions words: [String],
        forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        index.pointee = -1
        // The list opens only when a completion left the text as it is, so the last one
        // applied holds the matches, already worked out off the main actor.
        guard let completion = lastCompletion, completion.completedText == textView.string else {
            return []
        }
        let text = textView.string as NSString
        let slash = text.range(of: "/", options: .backwards)
        guard slash.location != NSNotFound else { return [] }
        let componentStart = NSMaxRange(slash)
        return completion.matches.prefix(500).map { match in
            let fullName = match.name + (match.isFolder ? "/" : "")
            if charRange.location <= componentStart {
                let between = NSRange(
                    location: charRange.location, length: componentStart - charRange.location)
                return text.substring(with: between) + fullName
            }
            let typedPrefix = text.substring(
                with: NSRange(
                    location: componentStart, length: charRange.location - componentStart))
            if let prefixRange = fullName.range(
                of: typedPrefix, options: [.anchored, .caseInsensitive])
            {
                return String(fullName[prefixRange.upperBound...])
            }
            return String(fullName.dropFirst(typedPrefix.count))
        }
    }
}
