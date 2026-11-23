import AppKit
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import BrowserKit
@testable import TwinPanesCore

/// Row icons drawn once per type, scale and appearance, off the main actor
/// (docs/plans/M4.md, performance pass, steps 3a and 3b).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct BrowserIconTests {
    let center = NotificationCenter()

    func entry(_ name: String, _ type: UTType) -> DirectoryEntry {
        DirectoryEntry(
            url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: type == .folder,
            isPackage: false, isSymbolicLink: false, isHidden: false, size: nil, modified: nil,
            type: type)
    }

    /// Waits for the cache's next `didChange`.
    func changed(_ cache: IconCache, in center: NotificationCenter) async {
        final class Token { var value: NSObjectProtocol? }
        let token = Token()
        await withCheckedContinuation { done in
            token.value = center.addObserver(
                forName: IconCache.didChange, object: cache, queue: nil
            ) { _ in
                center.removeObserver(token.value!)
                done.resume()
            }
        }
    }

    /// The icon once it's drawn.
    func loaded(
        _ cache: IconCache, _ entry: DirectoryEntry, scale: CGFloat = 2,
        appearance: NSAppearance.Name = .aqua
    ) async -> NSImage {
        while true {
            if let icon = cache.icon(for: entry, scale: scale, appearance: appearance) {
                return icon
            }
            await changed(cache, in: center)
        }
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func anIconIsOneBitmapAtTheScreensScale(scale: Double) async throws {
        let cache = IconCache(center: center)
        let icon = await loaded(cache, entry("a.txt", .plainText), scale: scale)
        #expect(icon.size == NSSize(width: 16, height: 16))
        #expect(icon.representations.count == 1)
        let rep = try #require(icon.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == Int(16 * scale) && rep.pixelsHigh == Int(16 * scale))
        #expect(rep.size == NSSize(width: 16, height: 16))
    }

    @Test func iconsAreKeptPerTypeScaleAndAppearance() async {
        let cache = IconCache(center: center)
        let text = entry("a.txt", .plainText)
        let light = await loaded(cache, text)
        #expect(await loaded(cache, entry("b.txt", .plainText)) === light)
        #expect(await loaded(cache, text, scale: 1) !== light)
        #expect(await loaded(cache, text, appearance: .darkAqua) !== light)
        #expect(await loaded(cache, entry("a.png", .png)) !== light)
    }

    /// The first ask has no icon; asking again meanwhile doesn't draw it twice.
    @Test func iconsAreDrawnOffTheMainActorOnce() async {
        final class Drawn: Sendable { let onMain = Mutex<[Bool]>([]) }  // one per drawing
        let drawn = Drawn()
        let cache = IconCache(center: center) { key in
            drawn.onMain.withLock { $0.append(Thread.isMainThread) }
            return IconCache.render(key)
        }
        let text = entry("a.txt", .plainText)
        #expect(cache.icon(for: text, scale: 2, appearance: .aqua) == nil)
        #expect(cache.icon(for: text, scale: 2, appearance: .aqua) == nil)
        _ = await loaded(cache, text)
        #expect(drawn.onMain.withLock { $0 } == [false])
    }

    /// Colour changes and coming back draw again; the old icon shows until then.
    @Test func colourChangesAndComingBackDrawAgain() async {
        let cache = IconCache(center: center)
        let text = entry("a.txt", .plainText)
        var icon = await loaded(cache, text)
        for name in [
            NSColor.systemColorsDidChangeNotification, NSApplication.didBecomeActiveNotification,
        ] {
            center.post(name: name, object: nil)
            #expect(cache.icon(for: text, scale: 2, appearance: .aqua) === icon)
            var again = icon
            while again === icon {
                await changed(cache, in: center)
                again = cache.icon(for: text, scale: 2, appearance: .aqua) ?? icon
            }
            icon = again
        }
    }

    @Test func aChangedAppIsLookedUpAgain() async {
        let cache = IconCache(center: center)
        let app = entry("Tool.app", .application)
        #expect(app.isApplication && !entry("a.txt", .plainText).isApplication)
        let icon = await loaded(cache, app)
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) === icon)
        cache.forget(path: app.url.path)
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) == nil)
        #expect(await loaded(cache, app) !== icon)
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
        let entry = try #require(item.entries.first { $0.name == "a.txt" })
        let shared = IconCache.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            let scale = window.backingScaleFactor
            // Each didChange reaches the table first, which gives its cells their icons.
            while true {
                let wanted = shared.icon(for: entry, scale: scale, appearance: appearance)
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell
                if let wanted, cell?.icon === wanted { break }
                await changed(shared, in: .default)
            }
        }
    }
}
