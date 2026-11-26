import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// The conflict sheet (docs/plans/M6.md, D-d, step 15).
@MainActor
@Suite struct ConflictSheetTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConflictSheetTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL

    init() throws {
        let fm = FileManager.default
        for folder in ["src/docs", "dest/docs"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(count: 2048).write(to: root.appendingPathComponent("src/a.txt"))
        try Data(count: 10).write(to: root.appendingPathComponent("dest/a.txt"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func conflict(_ source: String, _ existing: String) throws -> Conflict {
        let system = RealFileOperationSystem()
        let sourceURL = root.appendingPathComponent(source)
        let existingURL = root.appendingPathComponent(existing)
        return Conflict(
            item: PlannedItem(
                source: sourceURL, relativePath: sourceURL.lastPathComponent,
                metadata: try system.metadata(of: sourceURL)),
            existing: existingURL, existingMetadata: try system.metadata(of: existingURL))
    }

    @Test func aFileOffersReplaceSkipKeepBothAndStop() throws {
        defer { cleanUp() }
        let sheet = ConflictSheet(try conflict("src/a.txt", "dest/a.txt"))
        #expect(sheet.alert.buttons.map(\.title) == ["Replace", "Skip", "Keep Both", "Stop"])
        #expect(sheet.alert.buttons.last?.keyEquivalent == "\u{1b}")
        #expect(sheet.alert.messageText == "An item named “a.txt” already exists in “dest”.")
        #expect(sheet.alert.informativeText.contains("2 KB"))
        #expect(sheet.alert.informativeText.contains("10 bytes"))
    }

    @Test func aDanglingSymlinkReportsAliasAndItsOwnDate() throws {
        defer { cleanUp() }
        let fm = FileManager.default
        let sourceLink = root.appendingPathComponent("src/link")
        let destLink = root.appendingPathComponent("dest/link")
        try fm.createSymbolicLink(atPath: sourceLink.path, withDestinationPath: "/nonexistent/one")
        try fm.createSymbolicLink(atPath: destLink.path, withDestinationPath: "/nonexistent/two")
        let sheet = ConflictSheet(try conflict("src/link", "dest/link"))
        #expect(sheet.alert.informativeText.contains("alias, modified "))
    }

    @Test func aFolderOffersMergeFirst() throws {
        defer { cleanUp() }
        let sheet = ConflictSheet(try conflict("src/docs", "dest/docs"))
        #expect(sheet.alert.buttons.first?.title == "Merge")
    }

    @Test func anItemOntoItselfOffersKeepBoth() throws {
        defer { cleanUp() }
        let sheet = ConflictSheet(try conflict("src/a.txt", "src/a.txt"))
        #expect(sheet.alert.buttons.map(\.title) == ["Keep Both", "Skip", "Stop"])
    }

    @Test func applyToAllGoesWithTheChoice() async throws {
        defer { cleanUp() }
        let sheet = ConflictSheet(try conflict("src/a.txt", "dest/a.txt"))
        #expect(sheet.answer(forButtonAt: 2) == ConflictAnswer(.keepBoth))
        sheet.applyToAll.state = .on
        #expect(sheet.answer(forButtonAt: 1) == ConflictAnswer(.skip, applyToAll: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        async let answer = sheet.ask(on: window)
        await Task.yield()
        sheet.alert.buttons[0].performClick(nil)
        #expect(await answer == ConflictAnswer(.replace, applyToAll: true))
    }

    @Test func dismissEndsAttachedSheetWithStop() async throws {
        defer { cleanUp() }
        let sheet = ConflictSheet(try conflict("src/a.txt", "dest/a.txt"))
        sheet.applyToAll.state = .on
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        async let answer = sheet.ask(on: window)
        await Task.yield()
        sheet.dismiss(on: window)
        #expect(await answer == ConflictAnswer(.stop))
    }
}
