import AppKit
import Testing

@testable import BrowserKit

/// The path field's list of matches (PLAN.md §4.7, D49), answering AppKit's requests the
/// way the field makes them.
@MainActor
@Suite struct PathSuggestionsTests {
    /// The matches each typed text has, and the texts asked about.
    final class Folder {
        var matches = ["/x/Doc": ["/x/Documents/"], "/x/Dox": []]
        var asked: [String] = []
        var isListShowing = true
    }
    let folder = Folder()
    let suggestions: PathSuggestions
    let field = NSTextField()

    init() {
        suggestions = PathSuggestions(
            matchTexts: { [folder] typed in
                folder.asked.append(typed)
                return folder.matches[typed] ?? []
            },
            isShowing: { [folder] _ in folder.isListShowing })
    }

    /// The items `suggestions` answers a request with once the text is `typed`, waiting
    /// for matches worked out later.
    func answer(typed: String) async -> [String] {
        field.stringValue = typed
        return await withCheckedContinuation { answered in
            suggestions.textField(field) {
                answered.resume(returning: $0.itemSections.flatMap(\.items).map(\.representedValue))
            }
        }
    }

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

    @Test func typingWhileTheListShowsListsTheTypedTextsMatches() async {
        _ = list(["/x/Documents/", "/x/Downloads/"], typed: "/x/Do")
        _ = answer()
        #expect(await answer(typed: "/x/Doc") == ["/x/Documents/"])
    }

    @Test func typingOnceTheListClosedListsNothing() async {
        _ = list(["/x/Documents/", "/x/Downloads/"], typed: "/x/Do")
        _ = answer()
        folder.isListShowing = false
        #expect(await answer(typed: "/x/Doc").isEmpty)
        folder.isListShowing = true
        #expect(await answer(typed: "/x/Doc").isEmpty)
        #expect(folder.asked.isEmpty)
    }

    @Test func noMatchesCloseTheListForGood() async {
        _ = list(["/x/Documents/"], typed: "/x/Do")
        _ = answer()
        #expect(await answer(typed: "/x/Dox").isEmpty)
        #expect(await answer(typed: "/x/Doc").isEmpty)
        #expect(folder.asked == ["/x/Dox"])
    }

    @Test(arguments: ["picked", "field closed"])
    func pickingOrClosingTheFieldEndsTheList(how: String) async {
        _ = list(["/x/Documents/"], typed: "/x/Do")
        _ = answer()
        if how == "picked" {
            let item = PathSuggestions.Item(representedValue: "/x/Documents/", title: "")
            suggestions.textField(field, didSelect: item)
        } else {
            suggestions.endListing()
        }
        #expect(await answer(typed: "/x/Doc").isEmpty)
        #expect(folder.asked.isEmpty)
    }

    @Test func aNewerRequestSupersedesOneStillMatching() async {
        let (asked, askedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let slow = PathSuggestions(
            matchTexts: { typed in
                guard typed == "/x/Do" else { return ["/x/Documents/"] }
                askedContinuation.yield()
                for await _ in release { break }
                return ["/x/Downloads/"]
            },
            isShowing: { _ in true })
        let textView = NSTextView()
        textView.string = "/x/D"
        field.stringValue = "/x/D"
        slow.list(["/x/Documents/", "/x/Downloads/"], in: textView)
        slow.textField(field) { _ in }
        field.stringValue = "/x/Do"
        var olderAnswered = false
        slow.textField(field) { _ in olderAnswered = true }
        let older = slow.filtering
        for await _ in asked { break }
        field.stringValue = "/x/Doc"
        let newer = await withCheckedContinuation { answered in
            slow.textField(field) {
                answered.resume(returning: $0.itemSections.flatMap(\.items).map(\.representedValue))
            }
        }
        releaseContinuation.yield()
        await older?.value
        #expect(newer == ["/x/Documents/"])
        #expect(!olderAnswered)
    }

    @Test func aPickLeavesTheCaretAfterTheText() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "/x/Documents/"
        editor.selectedRange = NSRange(location: 4, length: 9)
        let item = PathSuggestions.Item(representedValue: "/x/Documents/", title: "")
        suggestions.textField(field, didSelect: item)
        #expect(editor.selectedRange == NSRange(location: 13, length: 0))
    }

    @Test func aPickedItemBecomesTheFieldsText() {
        let item = PathSuggestions.Item(representedValue: "/x/Documents/", title: "/x/Documents/")
        #expect(suggestions.textField(field, textCompletionFor: item) == "/x/Documents/")
    }
}
