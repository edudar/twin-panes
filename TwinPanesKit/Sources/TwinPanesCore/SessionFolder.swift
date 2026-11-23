import Foundation

/// What a session folder says about the file it protects (docs/plans/M3c.md, D-a).
public struct SessionManifest: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format = SessionManifest.currentFormat
    /// The file's path when the session was made, for display and as a fallback.
    public var path: String
    /// An app-scoped bookmark of the file, to reach it again after a relaunch.
    public var bookmark: Data?
    /// The file as it was when the session opened it.
    public var identity: FileIdentity

    public init(path: String, bookmark: Data?, identity: FileIdentity) {
        self.path = path
        self.bookmark = bookmark
        self.identity = identity
    }
}

/// One session's folder, `<root>/<session id>/`, made on the first edit: the manifest,
/// and later the clone, the add buffer and the journal. A clean close marks it closed
/// and deletes it; a folder found unclosed at launch belongs to a session that crashed.
public struct SessionFolder: Sendable, Equatable {
    public let url: URL

    static let manifestName = "manifest.json"
    static let closedName = "closed"

    /// Where the app keeps session folders: `Application Support/Sessions` (the
    /// container's, when sandboxed).
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions")
    }

    public init(url: URL) { self.url = url }

    /// The same folder on disk, however its URL is spelled (`/var` or `/private/var`, a
    /// trailing slash from a directory listing).
    public static func == (a: SessionFolder, b: SessionFolder) -> Bool {
        a.url.resolvingSymlinksInPath().standardizedFileURL.path
            == b.url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Creates the folder for session `id` under `root` with its manifest.
    public static func create(
        in root: URL, id: UUID, manifest: SessionManifest
    ) throws
        -> SessionFolder
    {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = SessionFolder(url: root.appendingPathComponent(id.uuidString))
        // Not intermediate: fails if the folder is already there.
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: false)
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: folder.file(Self.manifestName), options: .atomic)
        } catch {
            folder.delete()
            throw error
        }
        return folder
    }

    public func manifest() throws -> SessionManifest {
        try JSONDecoder().decode(
            SessionManifest.self, from: Data(contentsOf: file(Self.manifestName)))
    }

    /// A file in the folder.
    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// The session closed cleanly; nothing in the folder is needed any more.
    public var isClosed: Bool { FileManager.default.fileExists(atPath: file(Self.closedName).path) }

    public func markClosed() throws { try Data().write(to: file(Self.closedName)) }

    public func delete() { try? FileManager.default.removeItem(at: url) }

    /// Deletes the folders under `root` that closed cleanly or never got a manifest, and
    /// returns the rest: sessions that crashed with unsaved edits, for recovery.
    public static func sweep(_ root: URL) -> [SessionFolder] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var crashed: [SessionFolder] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let folder = SessionFolder(url: entry)
            if folder.isClosed || (try? folder.manifest()) == nil {
                folder.delete()
            } else {
                crashed.append(folder)
            }
        }
        return crashed
    }
}
