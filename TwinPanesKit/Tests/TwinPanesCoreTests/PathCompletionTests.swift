import Foundation
import Testing

@testable import TwinPanesCore

/// Shell-style path completion (PLAN.md §4.7; docs/plans/M5.md, D-e, step 20).
@Suite struct PathCompletionTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func folder(_ name: String) -> PathCompletion.Candidate { .init(name: name, isFolder: true) }
    func file(_ name: String) -> PathCompletion.Candidate { .init(name: name, isFolder: false) }

    func complete(_ text: String, among names: [PathCompletion.Candidate]) throws -> PathCompletion
    {
        PathCompletion(
            query: try #require(PathCompletion.query(for: text, home: home)), names: names)
    }

    @Test func tildeMeansTheRealHomeAndStaysTyped() throws {
        let query = try #require(PathCompletion.query(for: "~/Doc", home: home))
        #expect(query.folder.path == "/Users/someone")
        #expect(try complete("~/Doc", among: [folder("Documents")]).completedText == "~/Documents/")
    }

    @Test func aLoneTildeCompletesInsideHome() throws {
        let query = try #require(PathCompletion.query(for: "~", home: home))
        #expect(query.folder.path == "/Users/someone")
        #expect(try complete("~", among: [folder("Music")]).completedText == "~/Music/")
    }

    @Test func anAbsolutePathCompletesItsLastComponent() throws {
        let query = try #require(PathCompletion.query(for: "/Appl", home: home))
        #expect(query.folder.path == "/")
        #expect(
            try complete("/Appl", among: [folder("Applications")]).completedText == "/Applications/"
        )
    }

    @Test(arguments: ["", "Documents", "./x", " /x"])
    func otherTextHasNothingToComplete(text: String) {
        #expect(PathCompletion.query(for: text, home: home) == nil)
    }

    @Test func matchingIgnoresCaseAndTakesTheNamesSpelling() throws {
        let completion = try complete("/x/doc", among: [folder("Documents"), file("notes")])
        #expect(completion.completedText == "/x/Documents/")
    }

    @Test func severalMatchesCompleteAsFarAsTheyAgree() throws {
        let completion = try complete(
            "/x/rep", among: [file("Report 1.txt"), file("Report 2.txt"), file("readme")])
        #expect(completion.completedText == "/x/Report ")
        #expect(completion.matches.map(\.name) == ["Report 1.txt", "Report 2.txt"])
    }

    @Test func aSingleFileGetsNoSlash() throws {
        #expect(try complete("/x/no", among: [file("notes.txt")]).completedText == "/x/notes.txt")
    }

    @Test func noMatchLeavesTheTextAlone() throws {
        let completion = try complete("/x/zz", among: [folder("a")])
        #expect(completion.completedText == "/x/zz" && completion.matches.isEmpty)
    }

    @Test func hiddenNamesNeedATypedDot() throws {
        let names = [folder(".git"), folder("src")]
        #expect(try complete("/x/", among: names).matches.map(\.name) == ["src"])
        #expect(try complete("/x/.", among: names).matches.map(\.name) == [".git"])
    }

    @Test func foldersComeFirstThenNames() throws {
        let completion = try complete(
            "/x/", among: [file("b.txt"), folder("zeta"), file("a.txt"), folder("Alpha")])
        #expect(completion.matches.map(\.name) == ["Alpha", "zeta", "a.txt", "b.txt"])
    }

    /// Random names and typing against a brute-force model of the rules.
    @Test(arguments: 0..<200)
    func randomNamesMatchTheModel(seed: Int) throws {
        var random = SplitMix64(seed: UInt64(seed))
        let letters = Array("aAbB.c ")
        func word() -> String {
            String(
                (0..<Int.random(in: 1...4, using: &random)).map { _ in
                    letters.randomElement(using: &random)!
                })
        }
        let names = Array(Set((0..<Int.random(in: 0...12, using: &random)).map { _ in word() }))
            .map { PathCompletion.Candidate(name: $0, isFolder: Bool.random(using: &random)) }
        let partial = Bool.random(using: &random) ? "" : String(word().prefix(2))
        let completion = try complete("/x/" + partial, among: names)

        let expected = names.filter { candidate in
            candidate.name.lowercased().hasPrefix(partial.lowercased())
                && (!candidate.name.hasPrefix(".") || partial.hasPrefix("."))
        }
        #expect(Set(completion.matches.map(\.name)) == Set(expected.map(\.name)), "seed \(seed)")
        let folders = completion.matches.prefix { $0.isFolder }
        #expect(folders.count == expected.count { $0.isFolder }, "folders first, seed \(seed)")
        guard let first = completion.matches.first else {
            return #expect(completion.completedText == "/x/" + partial, "seed \(seed)")
        }
        // The longest prefix of the first match that every match starts with, ignoring case.
        let shared =
            (0...first.name.count).last { length in
                let prefix = first.name.prefix(length).lowercased()
                return completion.matches.allSatisfy { $0.name.lowercased().hasPrefix(prefix) }
            } ?? 0
        let slash = completion.matches.count == 1 && first.isFolder ? "/" : ""
        #expect(
            completion.completedText == "/x/" + first.name.prefix(shared) + slash, "seed \(seed)")
    }
}
