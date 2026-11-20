import Darwin
import Foundation

/// The M0 sandbox spike (PLAN.md §5): checks, for one user grant, which of the editor's
/// write-path building blocks work, so the save strategy (§4.3) and the recovery
/// guarantee (§4.1) can be chosen per volume and grant type.
///
/// **File mode changes the probed file** (an in-place write of identical bytes, an
/// xattr, a Finder tag, and a replace that gives it a new inode). Point it at a
/// disposable test file. Folder mode works only on files it creates in its own scratch
/// subfolder and removes that subfolder afterwards.
public struct SandboxProbe: Sendable {
    /// A directory in the app's own container (Application Support), used to test
    /// whether clones and staging files can live there.
    public let containerDirectory: URL

    static let xattrName = "io.github.edudar.filer.probe"
    static let tagName = "FilerProbe"

    public init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
    }

    /// `Application Support/Probe` inside the app's container (or the user's Library
    /// when not sandboxed).
    public static func defaultContainerDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        let dir = base.appendingPathComponent("Probe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: Helpers

    func containerFile(named name: String) -> URL {
        containerDirectory.appendingPathComponent("\(name)-\(Self.shortID())")
    }
}
