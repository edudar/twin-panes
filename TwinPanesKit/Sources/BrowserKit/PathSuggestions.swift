import AppKit

/// The path field's list of matches (PLAN.md §4.7, D49): AppKit's suggestions menu, which
/// draws in the field's font when the field is `.small`, aligned with its text. AppKit
/// asks for suggestions whenever the text changes; until `list(_:in:)` opens the list this
/// answers with nothing, and while the list shows it answers with the typed text's matches.
@MainActor
final class PathSuggestions: NSObject, NSTextSuggestionsDelegate {
    typealias SuggestionItemType = String

    /// The whole texts the typed text's matches complete to; empty when it has none.
    private let matchTexts: @MainActor (String) async -> [String]
    /// Whether the list still shows under `textField`: Escape closes it without telling
    /// its delegate.
    private let isShowing: @MainActor (NSTextField) -> Bool
    /// The texts waiting to be listed, and the field's text they were listed for.
    private var waiting: (texts: [String], typed: String)?
    /// The list is open and answers typing with matches.
    private var isListing = false
    /// The latest request's matching, which a newer request cancels; for tests.
    private(set) var filtering: Task<Void, Never>?

    init(
        matchTexts: @escaping @MainActor (String) async -> [String],
        isShowing: @escaping @MainActor (NSTextField) -> Bool = PathSuggestions.listShows(under:)
    ) {
        self.matchTexts = matchTexts
        self.isShowing = isShowing
    }

    /// AppKit shows the list as a child window of the field's window.
    static func listShows(under textField: NSTextField) -> Bool {
        textField.window?.childWindows?.contains { $0.isVisible } ?? false
    }

    /// Stops answering typing with matches: the field closed.
    func endListing() {
        filtering?.cancel()
        filtering = nil
        waiting = nil
        isListing = false
    }

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
    /// for; while the list shows, with the typed text's matches once they're worked out;
    /// else with nothing. Every answer is final: an open request leaves AppKit waiting,
    /// with the field's progress indicator armed. No matches close the list.
    func textField(
        _ textField: NSTextField,
        provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void
    ) {
        filtering?.cancel()
        filtering = nil
        let typed = textField.stringValue
        if let waiting {
            self.waiting = nil
            answer(waiting.typed == typed ? waiting.texts : [], to: responseHandler)
        } else if isListing, isShowing(textField) {
            filtering = Task { [weak self] in
                guard let self else { return }
                let texts = await matchTexts(typed)
                if Task.isCancelled { return }
                filtering = nil
                answer(texts, to: responseHandler)
            }
        } else {
            answer([], to: responseHandler)
        }
    }

    private func answer(_ texts: [String], to responseHandler: (ItemResponse) -> Void) {
        isListing = !texts.isEmpty
        responseHandler(ItemResponse(items: texts.map { Item(representedValue: $0, title: $0) }))
    }

    func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
        item.representedValue
    }

    func textField(_ textField: NSTextField, didSelect item: Item) {
        isListing = false
    }
}
