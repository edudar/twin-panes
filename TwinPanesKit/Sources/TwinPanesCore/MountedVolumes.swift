import Foundation

/// A mounted volume as the sidebar lists it (docs/plans/M5.md, D-d).
public struct Volume: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let isEjectable: Bool

    public init(url: URL, name: String, isEjectable: Bool) {
        self.url = url
        self.name = name
        self.isEjectable = isEjectable
    }
}

/// The volumes the sidebar's Locations section shows: what Finder shows, the boot
/// volume first and the rest by name.
public enum MountedVolumes {
    /// What one mounted volume says about itself.
    struct Candidate: Equatable {
        var url: URL
        var name: String
        var isBrowsable: Bool
        var isInternal: Bool
        var isEjectable: Bool
        var isRemovable: Bool
    }

    /// The volumes mounted now. Reads the file system; call it off the main actor.
    public static func current() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsBrowsableKey, .volumeIsInternalKey,
            .volumeIsEjectableKey, .volumeIsRemovableKey,
        ]
        let keySet = Set(keys)
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return shown(
            urls.compactMap { url in
                // A volume that can't describe itself is going away (being unmounted):
                // it isn't listed.
                guard let values = try? url.resourceValues(forKeys: keySet) else {
                    return nil
                }
                return Candidate(
                    url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
                    isBrowsable: values.volumeIsBrowsable ?? false,
                    isInternal: values.volumeIsInternal ?? false,
                    isEjectable: values.volumeIsEjectable ?? false,
                    isRemovable: values.volumeIsRemovable ?? false)
            })
    }

    /// Browsable volumes that are the boot volume or not internal (so no system
    /// partitions), boot volume first, then by name. Ejectable or removable ones can be
    /// ejected.
    static func shown(_ candidates: [Candidate]) -> [Volume] {
        func isBoot(_ candidate: Candidate) -> Bool { candidate.url.path == "/" }
        return
            candidates
            .filter { $0.isBrowsable && (isBoot($0) || !$0.isInternal) }
            .sorted { a, b in
                if isBoot(a) != isBoot(b) { return isBoot(a) }
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame
                    ? a.url.path < b.url.path : order == .orderedAscending
            }
            .map {
                Volume(
                    url: $0.url, name: $0.name,
                    isEjectable: !isBoot($0) && ($0.isEjectable || $0.isRemovable))
            }
    }
}
