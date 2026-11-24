import AppKit

/// What a child launch reports to the smoke test that started it.
struct SmokeChildReport: Codable {
    var step: String
    var isSandboxed: Bool
    var processID: Int32
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

    func run() {
        let report = SmokeChildReport(
            step: step,
            isSandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            processID: ProcessInfo.processInfo.processIdentifier)
        do {
            try JSONEncoder().encode(report)
                .write(to: folder.appendingPathComponent("\(step).json"), options: .atomic)
            exit(0)
        } catch {
            // The parent sees no report and says so; this is for anyone reading the log.
            print("smoke child \(step): can't write its report: \(error)")
            exit(1)
        }
    }
}
