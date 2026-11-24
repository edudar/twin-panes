import AppKit
import WorkspaceKit

/// Brings main windows back after a relaunch through AppKit restoration (D23,
/// docs/plans/M5.md, D-c). AppKit decides whether to restore at all, from the system's
/// "Close windows when quitting an app" setting, and calls this class for each saved
/// window before `applicationDidFinishLaunching`.
final class MainWindowRestoration: NSObject, NSWindowRestoration {
    static let identifier = NSUserInterfaceItemIdentifier("mainWindow")

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let app = NSApp.delegate as? AppDelegate else {
                return completionHandler(nil, CocoaError(.featureUnsupported))
            }
            do {
                let saved = try WindowState(restorableStateFrom: state)
                completionHandler(app.openMainWindow(restoring: saved).window, nil)
            } catch {
                // AppKit leaves the window out; with none restored, the app opens a new
                // one as on a first launch.
                completionHandler(nil, error)
            }
        }
    }
}
