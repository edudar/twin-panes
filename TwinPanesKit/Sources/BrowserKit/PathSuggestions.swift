import AppKit

/// The path field's list of matches (PLAN.md §4.7, D49): AppKit's suggestions menu, which
/// draws in the field's font when the field is `.small`, aligned with its text. AppKit
/// asks for suggestions whenever the text changes; this answers with nothing, so the list
/// opens only when `list(_:in:)` asks for it.
@MainActor
final class PathSuggestions: NSObject, NSTextSuggestionsDelegate {
    typealias SuggestionItemType = String

    /// The texts waiting to be listed, and the field's text they were listed for.
    private var waiting: (texts: [String], typed: String)?

    /// Opens the list of `texts`, each the field's whole text if picked. AppKit asks for
    /// suggestions only when the text changes, so this puts the same text back, and
    /// AppKit asks at once.
    func list(_ texts: [String], in textView: NSTextView) {
        let typed = textView.string
        waiting = (texts, typed)
        textView.insertText(
            typed, replacementRange: NSRange(location: 0, length: (typed as NSString).length))
    }

    /// Answers with the waiting texts if the field still holds the text they were listed
    /// for, else with nothing. Either answer is final: an open request leaves AppKit
    /// waiting, with the field's progress indicator armed.
    func textField(
        _ textField: NSTextField,
        provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void
    ) {
        let listing = waiting.flatMap { $0.typed == textField.stringValue ? $0.texts : nil }
        waiting = nil
        let items = (listing ?? []).map { Item(representedValue: $0, title: $0) }
        responseHandler(ItemResponse(items: items))
    }

    func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
        item.representedValue
    }
}
