import AppKit
import Testing
import UniformTypeIdentifiers

@testable import BrowserKit
@testable import TwinPanesCore

/// Row icons drawn once per type, scale and appearance (docs/plans/M4.md, performance
/// pass, step 3a).
@MainActor
@Suite struct BrowserIconTests {
    let center = NotificationCenter()

    func entry(_ name: String, _ type: UTType) -> DirectoryEntry {
        DirectoryEntry(
            url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: type == .folder,
            isPackage: false, isSymbolicLink: false, isHidden: false, size: nil, modified: nil,
            type: type)
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func anIconIsOneBitmapAtTheScreensScale(scale: Double) throws {
        let cache = IconCache(center: center)
        let icon = cache.icon(for: entry("a.txt", .plainText), scale: scale, appearance: .aqua)
        #expect(icon.size == NSSize(width: 16, height: 16))
        #expect(icon.representations.count == 1)
        let rep = try #require(icon.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == Int(16 * scale) && rep.pixelsHigh == Int(16 * scale))
        #expect(rep.size == NSSize(width: 16, height: 16))
    }

    @Test func iconsAreKeptPerTypeScaleAndAppearance() {
        let cache = IconCache(center: center)
        let text = entry("a.txt", .plainText)
        let light = cache.icon(for: text, scale: 2, appearance: .aqua)
        #expect(cache.icon(for: entry("b.txt", .plainText), scale: 2, appearance: .aqua) === light)
        #expect(cache.icon(for: text, scale: 1, appearance: .aqua) !== light)
        #expect(cache.icon(for: text, scale: 2, appearance: .darkAqua) !== light)
        #expect(cache.icon(for: entry("a.png", .png), scale: 2, appearance: .aqua) !== light)
    }

    @Test func colourChangesAndComingBackEmptyTheCacheAndSaySo() {
        let cache = IconCache(center: center)
        let text = entry("a.txt", .plainText)
        var emptied = 0
        let token = center.addObserver(forName: IconCache.didEmpty, object: cache, queue: nil) {
            _ in emptied += 1
        }
        defer { center.removeObserver(token) }
        var icon = cache.icon(for: text, scale: 2, appearance: .aqua)
        for name in [
            NSColor.systemColorsDidChangeNotification, NSApplication.didBecomeActiveNotification,
        ] {
            center.post(name: name, object: nil)
            let again = cache.icon(for: text, scale: 2, appearance: .aqua)
            #expect(again !== icon)
            icon = again
        }
        #expect(emptied == 2)
    }

    @Test func aChangedAppIsLookedUpAgain() {
        let cache = IconCache(center: center)
        let app = entry("Tool.app", .application)
        let icon = cache.icon(for: app, scale: 2, appearance: .aqua)
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) === icon)
        cache.forget(path: app.url.path)
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) !== icon)
    }

    /// A visible cell gets the icon for the table's appearance when it changes.
    @Test func cellsFollowTheTablesAppearance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("a.txt").path, contents: nil)
        let prefs = root.appendingPathComponent("prefs").path
        let item = BrowserItem(
            folder: root, grants: FolderGrants(defaults: UserDefaults(suiteName: prefs)!)
        ) { _, _ in }
        defer { item.willClose() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = item.controller.view
        defer { window.close() }
        item.go()
        await item.listed()
        let table = item.controller.tableView
        window.contentView?.layoutSubtreeIfNeeded()
        let row = try #require(item.controller.row(named: "a.txt"))
        func cell() -> FileCell? {
            table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell
        }
        let entry = try #require(item.entries.first { $0.name == "a.txt" })
        let scale = window.backingScaleFactor
        #expect(cell()?.icon === IconCache.shared.icon(for: entry, scale: scale, appearance: .aqua))
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(
            cell()?.icon === IconCache.shared.icon(for: entry, scale: scale, appearance: .darkAqua))
    }
}
