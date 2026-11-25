import Foundation
import Testing

@testable import TwinPanesCore

/// The sidebar's favorites (docs/plans/M5.md, D-d, step 15).
@Suite struct FavoritesTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("FavoritesTests-\(UUID().uuidString)", isDirectory: true)
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func favorites() throws -> Favorites {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("defaults").path
        return Favorites(defaults: try #require(UserDefaults(suiteName: suite)), home: home)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func paths(_ urls: [URL]) -> [String] { urls.map(\.path) }

    @Test func aNewListIsTheStandardFolders() throws {
        defer { cleanUp() }
        let favorites = try favorites()
        #expect(
            paths(favorites.folders) == [
                "/Users/someone", "/Users/someone/Desktop", "/Users/someone/Documents",
                "/Users/someone/Downloads", "/Applications",
            ])
    }

    @Test func addingPutsAFolderAtTheEndOrWhereAsked() throws {
        defer { cleanUp() }
        let favorites = try favorites()
        favorites.add(URL(fileURLWithPath: "/Volumes/Work"))
        favorites.add(URL(fileURLWithPath: "/tmp"), at: 0)
        #expect(paths(favorites.folders).first == "/tmp")
        #expect(paths(favorites.folders).last == "/Volumes/Work")
    }

    @Test func addingAFolderAlreadyThereMovesIt() throws {
        defer { cleanUp() }
        let favorites = try favorites()
        favorites.add(URL(fileURLWithPath: "/Applications"), at: 0)
        #expect(paths(favorites.folders).first == "/Applications")
        #expect(favorites.folders.count == 5)
    }

    @Test func removingAllLeavesTheListEmpty() throws {
        defer { cleanUp() }
        let favorites = try favorites()
        for folder in favorites.folders { favorites.remove(folder) }
        #expect(favorites.folders.isEmpty)
    }

    @Test func theListIsKeptInTheDefaults() throws {
        defer { cleanUp() }
        try favorites().add(URL(fileURLWithPath: "/tmp"), at: 1)
        #expect(paths(try favorites().folders)[1] == "/tmp")
    }

    @Test func pathsAreKeptStandardized() throws {
        defer { cleanUp() }
        let favorites = try favorites()
        favorites.add(URL(fileURLWithPath: "/tmp/../Applications/./"))
        #expect(favorites.folders.count == 5)
    }

    @Test func unstandardizedHomeAndStoredPathsAreStandardized() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("defaults").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(["/tmp/../Applications/./"], forKey: Favorites.key)
        let unstandardizedHome = URL(fileURLWithPath: "/Users/someone/sub/../", isDirectory: true)
        let favorites = Favorites(defaults: defaults, home: unstandardizedHome)
        #expect(paths(favorites.standard).first == "/Users/someone")
        #expect(paths(favorites.folders) == ["/Applications"])
    }

    @Test func symlinkAndCaseVariantPathsMatchWithoutDuplicating() throws {
        defer { cleanUp() }
        let favorites = try favorites()
        favorites.add(URL(fileURLWithPath: "/tmp", isDirectory: true))
        favorites.add(URL(fileURLWithPath: "/private/tmp", isDirectory: true), at: 0)
        #expect(favorites.folders.count == 6)
        #expect(
            paths(favorites.folders).first
                == URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL.path)
        favorites.remove(URL(fileURLWithPath: "/tmp", isDirectory: true))
        #expect(favorites.folders.count == 5)

        if !BookmarkStore.isCaseSensitive(folder) {
            let sub = folder.appendingPathComponent("SubFolder", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let upper = folder.appendingPathComponent("SUBFOLDER", isDirectory: true)
            favorites.add(sub)
            favorites.add(upper, at: 0)
            #expect(favorites.folders.count == 6)
            favorites.remove(sub)
            #expect(favorites.folders.count == 5)
        }
    }

    @Test func removingMissingFolderLeavesDefaultsUnset() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("defaults").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        let favorites = Favorites(defaults: defaults, home: home)
        favorites.remove(URL(fileURLWithPath: "/Volumes/NotInList", isDirectory: true))
        #expect(defaults.object(forKey: Favorites.key) == nil)
    }

    @Test func addingClampsIndexAndMovesForward() throws {
        defer { cleanUp() }
        let favorites = try favorites()
        let first = URL(fileURLWithPath: "/Volumes/First", isDirectory: true)
        let last = URL(fileURLWithPath: "/Volumes/Last", isDirectory: true)
        favorites.add(first, at: -10)
        favorites.add(last, at: 999)
        #expect(paths(favorites.folders).first == "/Volumes/First")
        #expect(paths(favorites.folders).last == "/Volumes/Last")
        favorites.add(first, at: 2)
        #expect(paths(favorites.folders)[2] == "/Volumes/First")
    }
}

/// The sidebar's Locations (docs/plans/M5.md, D-d, step 15).
@Suite struct MountedVolumesTests {
    func candidate(
        _ path: String, _ name: String, builtIn: Bool = false, browsable: Bool = true,
        ejectable: Bool = false, removable: Bool = false
    ) -> MountedVolumes.Candidate {
        MountedVolumes.Candidate(
            url: URL(fileURLWithPath: path, isDirectory: true), name: name,
            isBrowsable: browsable, isInternal: builtIn, isEjectable: ejectable,
            isRemovable: removable)
    }

    @Test func theBootVolumeComesFirstAndTheRestByName() {
        let shown = MountedVolumes.shown([
            candidate("/Volumes/Zeta", "Zeta"), candidate("/", "Macintosh HD", builtIn: true),
            candidate("/Volumes/alpha", "alpha"),
        ])
        #expect(shown.map(\.name) == ["Macintosh HD", "alpha", "Zeta"])
    }

    @Test func otherInternalAndUnbrowsableVolumesAreLeftOut() {
        let shown = MountedVolumes.shown([
            candidate("/", "Macintosh HD", builtIn: true),
            candidate("/System/Volumes/Data", "Data", builtIn: true),
            candidate("/Volumes/Hidden", "Hidden", browsable: false),
        ])
        #expect(shown.map(\.name) == ["Macintosh HD"])
    }

    @Test func ejectableOrRemovableVolumesCanBeEjected() {
        let shown = MountedVolumes.shown([
            candidate("/", "Macintosh HD", builtIn: true),
            candidate("/Volumes/USB", "USB", removable: true),
            candidate("/Volumes/Image", "Image", ejectable: true),
            candidate("/Volumes/NAS", "NAS"),
        ])
        #expect(shown.map(\.isEjectable) == [false, true, false, true])
    }

    @Test func theVolumesMountedNowStartWithTheBootVolume() {
        #expect(MountedVolumes.current().first?.url.path == "/")
    }

    @Test func externalBootVolumeIsNotEjectable() {
        let shown = MountedVolumes.shown([
            candidate("/", "External SSD", builtIn: false, ejectable: true, removable: true),
            candidate("/Volumes/USB", "USB", removable: true),
        ])
        #expect(shown.map(\.isEjectable) == [false, true])
    }

    @Test func duplicateVolumeNamesSortByPath() {
        let shown = MountedVolumes.shown([
            candidate("/Volumes/Work-2", "Work"),
            candidate("/Volumes/Work-1", "Work"),
        ])
        #expect(shown.map(\.url.path) == ["/Volumes/Work-1", "/Volumes/Work-2"])
    }
}
