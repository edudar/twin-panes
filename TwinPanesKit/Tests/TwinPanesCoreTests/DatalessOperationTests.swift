import Foundation
import Testing

@testable import TwinPanesCore

/// Files whose bytes are only in iCloud (docs/plans/M6.md, D-h, step 12).
@Suite struct DatalessOperationTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DatalessOperationTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()

    /// src/ cloud.bin (dataless), local.txt; dest/
    var source: URL { root.appendingPathComponent("src", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }
    var cloud: URL { source.appendingPathComponent("cloud.bin") }

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(count: 4).write(to: cloud)
        try Data("x".utf8).write(to: source.appendingPathComponent("local.txt"))
        system.markDataless([cloud.path])
        system.useTrash(root.appendingPathComponent("Trash", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func copy(control: OperationControl = OperationControl()) -> (CopyOutcome, [OperationProgress])
    {
        var reports: [OperationProgress] = []
        let outcome = FileOperationQueue.run(
            .copy([source], into: destination), fileSystem: system, control: control,
            resolve: { _ in ConflictAnswer(.stop) }, progress: { reports.append($0) })
        guard case .copied(let copied) = outcome else { return (CopyOutcome(), reports) }
        return (copied, reports)
    }

    @Test func aWalkNotesDatalessFiles() {
        defer { cleanUp() }
        let walk = OperationPlanner(fileSystem: system).walk(source)
        #expect(walk.items.filter(\.metadata.isDataless).map(\.relativePath) == ["src/cloud.bin"])
    }

    @Test func aCopyDownloadsFirstAndSaysSo() {
        defer { cleanUp() }
        let (outcome, reports) = copy()
        #expect(outcome.failures.isEmpty && system.downloads == [cloud.path])
        #expect(reports.contains { $0.isDownloading && $0.currentItem == "src/cloud.bin" })
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("src/cloud.bin").path))
    }

    @Test func aFailedDownloadIsThatItemsFailure() {
        defer { cleanUp() }
        system.failDownload(endingWith: "cloud.bin", errno: ENETDOWN)
        let (outcome, _) = copy()
        #expect(outcome.failures.map(\.errno) == [ENETDOWN])
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("src/cloud.bin").path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("src/local.txt").path))
    }

    @Test func cancellingDuringADownloadStops() {
        defer { cleanUp() }
        let control = OperationControl()
        system.onDownload { _ in control.cancel() }
        let (outcome, _) = copy(control: control)
        #expect(outcome.wasCancelled && outcome.failures.isEmpty)
    }

    @Test func renameMoveAndTrashDontDownload() {
        defer { cleanUp() }
        _ = FileOperationQueue.run(
            .rename(cloud, to: "renamed.bin"), fileSystem: system, control: OperationControl(),
            resolve: { _ in ConflictAnswer(.stop) }, progress: { _ in })
        let renamed = source.appendingPathComponent("renamed.bin")
        system.markDataless([renamed.path])
        _ = FileOperationQueue.run(
            .move([renamed], into: destination), fileSystem: system, control: OperationControl(),
            resolve: { _ in ConflictAnswer(.stop) }, progress: { _ in })
        _ = FileOperationQueue.run(
            .trash([destination.appendingPathComponent("renamed.bin")]), fileSystem: system,
            control: OperationControl(), resolve: { _ in ConflictAnswer(.stop) }, progress: { _ in }
        )
        #expect(system.downloads.isEmpty)
    }
}
