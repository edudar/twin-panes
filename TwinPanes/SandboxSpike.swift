import AppKit
import SandboxProbe

/// Debug-menu front end for the M0 sandbox spike (PLAN.md §5). Each run appends a
/// Markdown section to `Application Support/Probe/report.md` in the app's container and
/// shows the whole report in a tab. Bookmarks from each run are kept for the relaunch
/// check ("Resolve Saved Bookmarks" after quitting and relaunching).
@MainActor
final class SandboxSpike {
    private unowned let app: AppDelegate
    private var reportItem: ReportItem?
    private static let bookmarksKey = "SandboxSpike.bookmarks"

    init(app: AppDelegate) { self.app = app }

    private var containerDirectory: URL? { try? SandboxProbe.defaultContainerDirectory() }
    private var reportURL: URL? { containerDirectory?.appendingPathComponent("report.md") }

    func probeFile() {
        let panel = NSOpenPanel()
        panel.message =
            "Choose a DISPOSABLE test file. The probe rewrites a byte, adds an xattr and a "
            + "Finder tag, and replaces the file (new inode)."
        panel.prompt = "Probe File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        run(panel) { probe, url in probe.probeFile(url) }
    }

    func probeFolder() {
        let panel = NSOpenPanel()
        panel.message =
            "Choose a folder on the volume to test. The probe works in its own TwinPanesProbe-… "
            + "subfolder and removes it afterwards."
        panel.prompt = "Probe Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        run(panel) { probe, url in probe.probeFolder(url) }
    }

    func resolveSavedBookmarks() {
        let saved = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        var lines = [
            "### Relaunch check — \(saved.count) saved bookmark(s)", "",
            "| Probe | Result | Detail |", "|---|---|---|",
        ]
        for data in saved {
            let result = SandboxProbe.resolveSavedBookmark(data)
            lines.append("| \(result.name) | \(result.outcome.symbol) | \(result.outcome.detail) |")
        }
        append(lines.joined(separator: "\n") + "\n")
    }

    func showReport() {
        let text =
            reportURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "No spike runs yet. Use Debug › Probe a Test File… or Probe a Folder…"
        if let reportItem, app.controller(containing: reportItem.id) != nil {
            reportItem.update(text: text)
            app.controller(containing: reportItem.id)?.layout.select(reportItem.id)
        } else {
            let item = ReportItem(title: "Spike Report", text: text)
            reportItem = item
            app.show(item)
        }
    }

    func exportReport() {
        guard let reportURL, FileManager.default.fileExists(atPath: reportURL.path) else {
            showReport()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sandbox-spike-report.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: reportURL, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Private

    private func run(_ panel: NSOpenPanel, _ body: @escaping (SandboxProbe, URL) -> ProbeReport) {
        guard panel.runModal() == .OK, let url = panel.url, let containerDirectory else { return }
        let report = body(SandboxProbe(containerDirectory: containerDirectory), url)
        if let bookmark = report.bookmark {
            var saved = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
            saved.append(bookmark)
            UserDefaults.standard.set(saved, forKey: Self.bookmarksKey)
        }
        append(report.markdown)
        app.activeController?.frameController.showStatus(
            "Probe finished: \(report.failureCount) failing step(s) — see Spike Report")
    }

    private func append(_ markdown: String) {
        guard let reportURL else { return }
        let existing =
            (try? String(contentsOf: reportURL, encoding: .utf8))
            ?? "# Twin Panes sandbox spike report\n\n"
        try? (existing + "\n" + markdown).write(to: reportURL, atomically: true, encoding: .utf8)
        showReport()
    }
}
