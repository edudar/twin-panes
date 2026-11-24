import AppKit

/// What a child launch reports to the smoke test that started it.
struct SmokeChildReport: Codable {
    var step: String
    var isSandboxed: Bool
    var processID: Int32
    /// What a restored window shows, from the `restore-load` step.
    var shown: ShownWindow?
}

/// A restored window as the restore relaunch checks it (docs/plans/M5.md, D-f, 1).
struct ShownWindow: Codable {
    var leftTabs: [String]
    var rightTabs: [String]
    var activePanel: String
    var leftFolder: String
    var leftSelection: String?
    var leftCanGoBack: Bool
    var leftCanGoForward: Bool
    var leftSort: String
    var leftShowsHidden: Bool
    var editorFile: String?
    var editorSelection: [UInt64]?
    var editorBytesPerRow: String?
    var editorIsDirty: Bool?
}

/// The app as the smoke test's child, `--smoke-child <step> <folder>`
/// (docs/plans/M5.md, D-f): it does its step, writes `<step>.json` into the folder for
/// the parent, and quits.
@MainActor
struct SmokeChild {
    static let flag = "--smoke-child"

    let step: String
    let folder: URL

    /// Nil when this launch isn't a child's.
    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: Self.flag), arguments.count > index + 2
        else { return nil }
        step = arguments[index + 1]
        folder = URL(fileURLWithPath: arguments[index + 2], isDirectory: true)
    }

    func run(app: AppDelegate) {
        Task { @MainActor in
            var report = SmokeChildReport(
                step: step,
                isSandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
                    != nil,
                processID: ProcessInfo.processInfo.processIdentifier)
            do {
                switch step {
                case "ping": break
                case "restore-save": try await saveWindow(app: app)
                case "restore-load": report.shown = try await loadWindow(app: app)
                default: throw SmokeChildError.unknownStep(step)
                }
                try JSONEncoder().encode(report)
                    .write(to: folder.appendingPathComponent("\(step).json"), options: .atomic)
                // `exit` skips teardown: close sessions as quitting does.
                app.applicationWillTerminate(
                    Notification(name: NSApplication.willTerminateNotification))
                exit(0)
            } catch {
                // The parent sees no report and says so; this is for anyone reading the log.
                print("smoke child \(step): \(error)")
                exit(1)
            }
        }
    }
}
