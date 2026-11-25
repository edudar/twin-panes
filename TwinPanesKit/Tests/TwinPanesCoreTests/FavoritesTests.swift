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
}
