import Foundation

/// What the in-tab access prompt asks for (docs/plans/M4.md, D-g): where the open panel
/// starts, the button, and why. One grant should cover as much as the user means: the
/// whole volume for an external drive, the home folder inside it, or the grant that was
/// lost when its folder was renamed, moved or unmounted.
struct AccessRequest: Equatable {
    var directory: URL
    var button: String
    var message: String

    static func `for`(
        folder: URL, lost: URL?, home: URL, volume: URL? = nil, coveringGrant: URL? = nil
    ) -> AccessRequest {
        let name = folder.path == "/" ? "/" : folder.lastPathComponent
        if let lost {
            return AccessRequest(
                directory: lost, button: "Grant Access Again…",
                message: "Twin Panes had access to “\(lost.lastPathComponent)”, but lost it: "
                    + "it may have been renamed, moved or unmounted. Grant it again to show "
                    + "“\(name)”.")
        }
        let standardized = folder.standardizedFileURL
        if coveringGrant == nil {
            if let volumeURL = nonRootVolumeURL(for: standardized, volume: volume) {
                let volumeName = volumeURL.lastPathComponent
                let message =
                    standardized.path == volumeURL.path
                    ? "Grant access to “\(volumeName)” once and it’s remembered."
                    : "“\(name)” is on “\(volumeName)”. Grant access to the whole volume once "
                        + "and it’s remembered."
                return AccessRequest(
                    directory: volumeURL,
                    button: "Grant Access to “\(volumeName)”…",
                    message: message)
            }
            if standardized.pathComponents.starts(with: home.standardizedFileURL.pathComponents) {
                return AccessRequest(
                    directory: home, button: "Grant Access to Your Home Folder…",
                    message: "Twin Panes needs your permission to show “\(name)”. Grant access "
                        + "to your home folder once and it’s remembered. macOS may still ask "
                        + "about Desktop, Documents, Downloads and iCloud Drive.")
            }
        }
        return AccessRequest(
            directory: folder, button: "Grant Access…",
            message: "Twin Panes needs your permission to show “\(name)”.\n"
                + "Grant access once and it’s remembered.")
    }

    private static func nonRootVolumeURL(for folder: URL, volume: URL?) -> URL? {
        if let volume {
            let standardized = volume.standardizedFileURL
            return standardized.path == "/" ? nil : standardized
        }
        let parts = folder.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            return URL(fileURLWithPath: "/Volumes/\(parts[2])", isDirectory: true)
        }
        return nil
    }
}
