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
        let text = textView.string
        guard let names = completionNames,
            let query = PathCompletion.query(for: text, home: DirectoryReader.realHomeDirectory)
        else {
            NSSound.beep()
            return true
        }
        if let cached = names.cached(in: query.folder) {
            apply(PathCompletion(query: query, names: cached), to: textView, typed: text)
            return true
        }
        pendingCompletion = Task { [weak self, weak textView] in
            guard let found = await names.names(in: query.folder), let self, let textView,
                textView.string == text
            else { return }
            apply(PathCompletion(query: query, names: found), to: textView, typed: text)
        }
        return true
    }

    private func apply(_ completion: PathCompletion, to textView: NSTextView, typed: String) {
        if completion.completedText != typed {
            let whole = NSRange(location: 0, length: (typed as NSString).length)
            textView.insertText(completion.completedText, replacementRange: whole)
        } else if completion.matches.count > 1 {
            showCompletionList(textView)
        } else {
            NSSound.beep()
        }
    }

    /// The matches for the text in the field now, from names already read.
    private func currentMatches(in textView: NSTextView) -> [PathCompletion.Candidate] {
        guard
            let query = PathCompletion.query(
                for: textView.string, home: DirectoryReader.realHomeDirectory),
            let names = completionNames?.cached(in: query.folder)
        else { return [] }
        return PathCompletion(query: query, names: names).matches
    }

    /// AppKit's completion list: each match as a replacement for `charRange`, AppKit's
    /// idea of the last word, which stops at spaces and `/` as well.
    func control(
        _ control: NSControl, textView: NSTextView, completions words: [String],
        forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        index.pointee = -1
        let text = textView.string as NSString
        let componentStart = NSMaxRange(text.range(of: "/", options: .backwards))
        return currentMatches(in: textView).map { match in
            let name = (match.name + (match.isFolder ? "/" : "")) as NSString
            if charRange.location <= componentStart {
                let between = NSRange(
                    location: charRange.location, length: componentStart - charRange.location)
                return text.substring(with: between) + (name as String)
            }
            return name.substring(from: min(charRange.location - componentStart, name.length))
        }
    }
}
