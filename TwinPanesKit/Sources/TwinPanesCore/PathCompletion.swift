import Foundation

/// Shell-style completion of the path typed in the path field (PLAN.md §4.7;
/// docs/plans/M5.md, D-e). Pure: the folder's names come from the caller.
public struct PathCompletion: Equatable, Sendable {
    /// One name in the folder being completed.
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let isFolder: Bool

        public init(name: String, isFolder: Bool) {
            self.name = name
            self.isFolder = isFolder
        }
    }

    /// What typed text asks to complete: the folder to read, the text up to and including
    /// its last `/` as typed, and the partial last component.
    public struct Query: Equatable, Sendable {
        public let folder: URL
        let typedFolder: String
        let partial: String
    }

    /// The matches, folders first, then by name as the file list sorts them.
    public let matches: [Candidate]
    /// The typed text with the last component completed as far as every match agrees,
    /// in the matches' spelling; a folder that's the only match gets a trailing `/`.
    public let completedText: String

    /// The query `text` asks for, or nil when it isn't an absolute path or one starting
    /// with `~`, which means `home` (the real home folder, not the app's container).
    public static func query(for text: String, home: URL) -> Query? {
        let typed = text == "~" ? "~/" : text
        guard typed.hasPrefix("/") || typed.hasPrefix("~/"), let slash = typed.lastIndex(of: "/")
        else { return nil }
        let typedFolder = String(typed[...slash])
        let path =
            typedFolder.hasPrefix("~/") ? home.path + "/" + typedFolder.dropFirst(2) : typedFolder
        return Query(
            folder: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
            typedFolder: typedFolder, partial: String(typed[typed.index(after: slash)...]))
    }

    /// Completes `query` among `names`. Matching ignores case; hidden names are offered
    /// only when the partial component starts with `.`.
    public init(query: Query, names: [Candidate]) {
        let partial = query.partial.lowercased()
        let offersHidden = partial.hasPrefix(".")
        matches = names.filter { candidate in
            (offersHidden || !candidate.name.hasPrefix("."))
                && candidate.name.lowercased().hasPrefix(partial)
        }.sorted(by: Self.inListOrder)
        guard let first = matches.first else {
            completedText = query.typedFolder + query.partial
            return
        }
        let shared = Self.sharedLength(of: matches.map(\.name))
        let slash = matches.count == 1 && first.isFolder ? "/" : ""
        completedText = query.typedFolder + first.name.prefix(shared) + slash
    }

    /// Folders first, then by name as Finder sorts it, then by the raw name so the order
    /// is total.
    private static func inListOrder(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.name < b.name : order == .orderedAscending
    }

    /// How many leading characters every name shares, ignoring case.
    private static func sharedLength(of names: [String]) -> Int {
        let characters = names.map { $0.map { String($0).lowercased() } }
        let shortest = characters.map(\.count).min() ?? 0
        return (0..<shortest).first { index in
            characters.contains { $0[index] != characters[0][index] }
        } ?? shortest
    }
}
