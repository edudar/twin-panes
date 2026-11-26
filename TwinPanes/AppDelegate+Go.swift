import AppKit
import TwinPanesCore

/// The Go menu (docs/reviews/Shortcuts.md, finding 2): Finder's places, opened in the
/// active panel as a sidebar click opens them, so a folder that needs access shows its
/// prompt there.
extension AppDelegate {
    @objc func goHome(_ sender: Any?) { go(to: Self.home) }
    @objc func goDesktop(_ sender: Any?) { go(to: Self.home.appendingPathComponent("Desktop")) }
    @objc func goDocuments(_ sender: Any?) {
        go(to: Self.home.appendingPathComponent("Documents"))
    }
    @objc func goDownloads(_ sender: Any?) {
        go(to: Self.home.appendingPathComponent("Downloads"))
    }
    @objc func goApplications(_ sender: Any?) { go(to: URL(filePath: "/Applications")) }
    @objc func goUtilities(_ sender: Any?) { go(to: URL(filePath: "/Applications/Utilities")) }

    private static var home: URL { DirectoryReader.realHomeDirectory }

    private func go(to folder: URL) {
        open(folder, inActivePanelOf: activeController ?? openMainWindow())
    }
}
