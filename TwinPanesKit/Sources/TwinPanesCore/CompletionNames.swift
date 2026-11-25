import Foundation

/// The names path completion offers, one folder's at a time (docs/plans/M5.md, D-e).
/// Each folder is read once, off the main actor, and kept while the path field is open,
/// so a 100k-entry folder never stalls typing. A folder that can't be read (no sandbox
/// grant, gone, not a folder) has no names, and nothing prompts for access.
@MainActor
public final class CompletionNames {
    public typealias Read = @Sendable (URL) -> [PathCompletion.Candidate]

    private let read: Read
    private let access: (URL) -> SecurityScope?
    private let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "CompletionNames"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private var cache: [String: [PathCompletion.Candidate]] = [:]
    private var inFlight: [String: Task<[PathCompletion.Candidate], Never>] = [:]
    private var latestRequest = 0

    /// `read` lists one folder off the main actor, while the scope `access` gives for it
    /// (on the main actor) is held.
    public init(read: @escaping Read, access: @escaping (URL) -> SecurityScope? = { _ in nil }) {
        self.read = read
        self.access = access
    }

    /// Reads folders the way the browser lists them, with access from `grants`.
    public convenience init(grants: FolderGrants) {
        self.init(read: Self.readFolder, access: { grants.scope(covering: $0) })
    }

    /// The names in `folder`, hidden ones included; packages count as files, as in the
    /// browser. Empty when the folder can't be read.
    nonisolated static func readFolder(_ folder: URL) -> [PathCompletion.Candidate] {
        // Completion offers nothing for a folder it can't read and never prompts
        // (PLAN.md §4.7); going to the folder reports why.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [])
        else {
            return []
        }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            let isFolder: Bool
            if values?.isSymbolicLink == true {
                let resolved = try? url.resolvingSymlinksInPath().resourceValues(
                    forKeys: [.isDirectoryKey, .isPackageKey])
                isFolder = (resolved?.isDirectory ?? false) && !(resolved?.isPackage ?? false)
            } else {
                isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            }
            return .init(name: url.lastPathComponent, isFolder: isFolder)
        }
    }

    /// The names already read for `folder`, or nil when they aren't yet.
    public func cached(in folder: URL) -> [PathCompletion.Candidate]? {
        cache[folder.standardizedFileURL.path]
    }

    /// The names in `folder`, read once. Returns nil when a request for another folder
    /// came while this one was being read: the caller's text has moved on.
    public func names(in folder: URL) async -> [PathCompletion.Candidate]? {
        let folder = folder.standardizedFileURL
        let key = folder.path
        latestRequest += 1
        let request = latestRequest
        if let names = cache[key] { return names }
        let task: Task<[PathCompletion.Candidate], Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let (read, access, readQueue) = (self.read, self.access, self.readQueue)
            task = Task {
                let scope = access(folder)
                let names = await withCheckedContinuation { continuation in
                    readQueue.addOperation {
                        let result = withExtendedLifetime(scope) { read(folder) }
                        continuation.resume(returning: result)
                    }
                }
                // Kept even when overtaken: the names are right, and typing may come back here.
                cache[key] = names
                inFlight[key] = nil
                return names
            }
            inFlight[key] = task
        }
        let names = await task.value
        return request == latestRequest ? names : nil
    }
}
