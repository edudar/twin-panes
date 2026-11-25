import AppKit
import Testing

@testable import BrowserKit

/// The path field's list of matches (PLAN.md §4.7, D49), answering AppKit's requests the
/// way the field makes them.
@MainActor
@Suite struct PathSuggestionsTests {
    let suggestions = PathSuggestions()
    let field = NSTextField()

    /// The items `suggestions` answers AppKit's next request with.
    func answer() -> [PathSuggestions.Item] {
        var answered: [PathSuggestions.Item] = []
        suggestions.textField(field) { answered = $0.itemSections.flatMap(\.items) }
        return answered
    }

    func list(_ texts: [String], typed: String) -> NSTextView {
        let textView = NSTextView()
        textView.string = typed
        field.stringValue = typed
        suggestions.list(texts, in: textView)
        return textView
    }

    @Test func typingOpensNoList() {
        field.stringValue = "/Users/someone/Do"
        #expect(answer().isEmpty)
    }

    @Test func listingAnswersTheNextRequestWithEachWholeText() {
        let texts = ["/x/Documents/", "/x/Downloads/"]
        _ = list(texts, typed: "/x/Do")
        let items = answer()
        #expect(items.map(\.representedValue) == texts)
        #expect(items.map(\.title) == texts)
    }

    @Test func listingLeavesTheTextAsItWas() {
        #expect(list(["/x/Documents/"], typed: "/x/Do").string == "/x/Do")
    }

    @Test func theListIsAnsweredOnce() {
        _ = list(["/x/Documents/"], typed: "/x/Do")
        _ = answer()
        #expect(answer().isEmpty)
    }

    @Test func textChangedSinceListingOpensNoList() {
        _ = list(["/x/Documents/"], typed: "/x/Do")
        field.stringValue = "/x/Dow"
        #expect(answer().isEmpty)
    }

    @Test func aPickedItemBecomesTheFieldsText() {
        let item = PathSuggestions.Item(representedValue: "/x/Documents/", title: "/x/Documents/")
        #expect(suggestions.textField(field, textCompletionFor: item) == "/x/Documents/")
    }
}
