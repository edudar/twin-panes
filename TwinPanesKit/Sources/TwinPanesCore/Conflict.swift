import Foundation

/// What to do when an item's name is taken at the destination (docs/plans/M6.md, D-d).
public enum ConflictChoice: Sendable, Equatable {
    /// The old item goes to the Trash and the new one takes its place.
    case replace
    case skip
    /// The new item gets the next free name: "name 2.ext", "name 3.ext"…
    case keepBoth
    /// A folder meeting a folder: go into it and carry on, asking per item inside.
    case merge
    /// Ends the operation; what's done stays done.
    case stop
}

/// An item whose name is taken at the destination.
public struct Conflict: Sendable {
    public let item: PlannedItem
    public let existing: URL
    public let existingMetadata: FileItemMetadata

    /// The item would land on itself: both panels show the same folder.
    public var isSameItem: Bool {
        BookmarkStore.sameEntry(item.source, existing)
    }

    /// The choices that make sense here, in the order the sheet shows them.
    public var choices: [ConflictChoice] {
        if isSameItem { return [.keepBoth, .skip, .stop] }
        if item.metadata.kind == .folder, existingMetadata.kind == .folder {
            return [.merge, .replace, .skip, .keepBoth, .stop]
        }
        return [.replace, .skip, .keepBoth, .stop]
    }
}

/// The user's answer; `applyToAll` repeats it for the rest of the operation's conflicts
/// of the same kind (files or folders).
public struct ConflictAnswer: Sendable, Equatable {
    public let choice: ConflictChoice
    public let applyToAll: Bool

    public init(_ choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

/// An item a Replace sent to the Trash, and where it went, so undo can put it back.
public struct TrashedItem: Sendable, Equatable {
    public let original: URL
    public let trashed: URL
}

/// Finder's Keep Both name: `name` with the first free number, "photo 2.jpg", then
/// "photo 3.jpg"; a name that already ends in a number counts on from it.
public enum KeepBothName {
    public static func next(for name: String, isTaken: (String) -> Bool) -> String {
        let ns = name as NSString
        // A leading dot is a hidden name, not an extension (".profile").
        let isDotName = name.hasPrefix(".") && !name.dropFirst().contains(".")
        let ext = isDotName ? "" : ns.pathExtension
        var base = ext.isEmpty ? name : ns.deletingPathExtension
        var number = 2
        if let space = base.lastIndex(of: " ") {
            let suffix = base[base.index(after: space)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber),
                let counted = Int(suffix), counted < Int.max
            {
                base = String(base[..<space])
                number = counted + 1
            }
        }
        while true {
            let candidate = "\(base) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            if !isTaken(candidate) { return candidate }
            if number == Int.max {
                base = "\(base) \(number)"
                number = 2
            } else {
                number += 1
            }
        }
    }
}
