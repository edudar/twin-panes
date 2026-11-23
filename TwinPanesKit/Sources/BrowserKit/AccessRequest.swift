import Foundation

/// What the in-tab access prompt asks for (docs/plans/M4.md, D-g): where the open panel
/// starts, the button, and why. One grant should cover as much as the user means: the
/// whole volume for an external drive, the home folder inside it, or the grant that was
/// lost when its folder was renamed, moved or unmounted.
struct AccessRequest: Equatable {
    var directory: URL
    var button: String
    var message: String

    static func `for`(folder: URL, lost: URL?, home: URL) -> AccessRequest {
        let name = folder.path == "/" ? "/" : folder.lastPathComponent
        if let lost {
            return AccessRequest(
                directory: lost, button: "Grant Access Again…",
                message: "Twin Panes had access to “\(lost.lastPathComponent)”, but lost it: "
                    + "it may have been renamed, moved or unmounted. Grant it again to show "
                    + "“\(name)”.")
        }
        let parts = folder.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            let volume = parts[2]
            return AccessRequest(
                directory: URL(fileURLWithPath: "/Volumes/\(volume)", isDirectory: true),
                button: "Grant Access to “\(volume)”…",
                message: "“\(name)” is on “\(volume)”. Grant access to the whole volume once "
                    + "and it’s remembered.")
        }
        if parts.starts(with: home.standardizedFileURL.pathComponents) {
            return AccessRequest(
                directory: home, button: "Grant Access to Your Home Folder…",
                message: "Twin Panes needs your permission to show “\(name)”. Grant access "
                    + "to your home folder once and it’s remembered. macOS may still ask "
                    + "about Desktop, Documents, Downloads and iCloud Drive.")
        }
        return AccessRequest(
            directory: folder, button: "Grant Access…",
            message: "Twin Panes needs your permission to show “\(name)”.\n"
                + "Grant access once and it’s remembered.")
    }
}
