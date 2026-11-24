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
        final class Token: @unchecked Sendable { var value: NSObjectProtocol? }
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
        appearance: NSAppearance.Name = .aqua, in center: NotificationCenter? = nil
    ) async -> NSImage {
        let targetCenter = center ?? self.center
        while true {
            if let icon = cache.icon(for: entry, scale: scale, appearance: appearance) {
                return icon
            }
            await changed(cache, in: targetCenter)
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
        cache.forget(["Tool.app"], in: URL(fileURLWithPath: "/tmp"))
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) == nil)
        #expect(await loaded(cache, app) !== icon)
    }

    /// A live update's names, up to tens of thousands while a big folder lists, are
    /// checked against the few cached app icons, not the other way round.
    @Test func forgettingNamesTouchesOnlyThatFolder() async {
        let cache = IconCache(center: center)
        let app = entry("Tool.app", .application)
        let elsewhere = DirectoryEntry(
            url: URL(fileURLWithPath: "/elsewhere/Tool.app"), name: "Tool.app",
            isDirectory: false, isPackage: true, isSymbolicLink: false, isHidden: false,
            size: nil, modified: nil, type: .application)
        let (here, there) = (await loaded(cache, app), await loaded(cache, elsewhere))
        let names = Set((0..<100_000).map { "f\($0)" }).union(["Tool.app"])
        cache.forget(names, in: URL(fileURLWithPath: "/tmp"))
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) == nil)
        #expect(cache.icon(for: elsewhere, scale: 2, appearance: .aqua) === there)
        #expect(here !== there)
    }

    /// A visible cell gets the icon for the table's appearance when it changes.
    @Test func cellsFollowTheTablesAppearance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("a.twinpanes-icon-test").path, contents: nil)
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
        let row = try #require(item.controller.row(named: "a.twinpanes-icon-test"))
        let entry = try #require(item.entries.first { $0.name == "a.twinpanes-icon-test" })
        let shared = IconCache.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            let scale = window.backingScaleFactor
            // No other test has this type: its dark icon isn't drawn yet.
            if appearance == .darkAqua { #expect(!item.shownIconsAreCurrent) }
            // Each didChange reaches the table first, which gives its cells their icons.
            while true {
                let wanted = shared.icon(for: entry, scale: scale, appearance: appearance)
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell
                if let wanted, cell?.icon === wanted { break }
                await changed(shared, in: .default)
            }
            #expect(item.shownIconsAreCurrent)
        }
    }

    @Test func forgettingDuringInFlightRenderDiscardsStaleIcon() async throws {
        let (started, startedCont) = AsyncStream.makeStream(of: Void.self)
        let proceed = DispatchSemaphore(value: 0)
        let cache = IconCache(center: center) { _ in
            startedCont.yield()
            proceed.wait()
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let app = entry("Tool.app", .application)
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) == nil)
        for await _ in started { break }
        cache.forget(["Tool.app"], in: URL(fileURLWithPath: "/tmp"))
        proceed.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(cache.icon(for: app, scale: 2, appearance: .aqua) == nil)
    }

    @Test func nilRenderDoesNotRetriggerLoads() async throws {
        final class Counter: Sendable { let count = Mutex(0) }
        let counter = Counter()
        let cache = IconCache(center: center) { _ in
            counter.count.withLock { $0 += 1 }
            return nil
        }
        let text = entry("missing.txt", .plainText)
        for _ in 0..<3 {
            #expect(cache.icon(for: text, scale: 2, appearance: .aqua) == nil)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(counter.count.withLock { $0 } == 1)
    }

    private func tempFolder() throws -> (URL, FolderGrants) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = root.appendingPathComponent("prefs").path
        return (root, FolderGrants(defaults: UserDefaults(suiteName: prefs)!))
    }

    @Test func customIconOnRegularFileLoadsAndUpdatesAfterForget() async throws {
        let (root, _) = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("custom.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("hello".utf8))
        func waitIcon(
            _ cache: IconCache, _ entry: DirectoryEntry, excluding: [NSImage]
        ) async throws -> NSImage? {
            for _ in 0..<20 {
                if let icon = cache.icon(for: entry, scale: 2, appearance: .aqua),
                    !excluding.contains(where: { $0 === icon })
                {
                    return icon
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        let sym = { (n: String) in NSImage(systemSymbolName: n, accessibilityDescription: nil)! }
        #expect(NSWorkspace.shared.setIcon(sym("star"), forFile: fileURL.path, options: []))
        let cache = IconCache(center: center)
        let plain = await loaded(cache, entry("plain.txt", .plainText))
        let custom = DirectoryEntry(
            url: fileURL, name: "custom.txt", isDirectory: false, isPackage: false,
            isSymbolicLink: false, isHidden: false, size: 5, modified: nil, type: .plainText)
        let first = try #require(await waitIcon(cache, custom, excluding: [plain]))
        #expect(NSWorkspace.shared.setIcon(sym("heart"), forFile: fileURL.path, options: []))
        cache.forget(["custom.txt"], in: root)
        #expect(try await waitIcon(cache, custom, excluding: [plain, first]) != nil)
    }

    @Test func deallocatingControllerRemovesIconObserver() throws {
        let (root, grants) = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        weak var weakController: BrowserViewController?
        weak var weakObserver: AnyObject?
        do {
            let item = BrowserItem(folder: root, grants: grants) { _, _ in }
            _ = item.controller.view
            weakController = item.controller
            weakObserver = item.controller.iconObserver as AnyObject?
            #expect(weakObserver != nil)
            item.willClose()
        }
        #expect(weakController == nil && weakObserver == nil)
    }

    @Test func refreshIconsUpdatesMovedNameColumn() async throws {
        let (root, grants) = try tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt").path
        FileManager.default.createFile(atPath: file, contents: nil)
        let item = BrowserItem(folder: root, grants: grants) { _, _ in }
        defer { item.willClose() }
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: .titled,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = item.controller.view
        defer { window.close() }
        item.go()
        await item.listed()
        let table = item.controller.tableView
        table.moveColumn(0, toColumn: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        let entry = try #require(item.entries.first { $0.name == "a.txt" })
        _ = await loaded(
            IconCache.shared, entry, scale: window.backingScaleFactor,
            appearance: table.effectiveAppearance.name, in: .default)
        let row = try #require(item.controller.row(named: "a.txt"))
        let cell = try #require(
            table.view(atColumn: 1, row: row, makeIfNecessary: false) as? FileCell)
        cell.icon = nil
        #expect(!item.shownIconsAreCurrent)
        item.controller.refreshIcons()
        #expect(cell.icon != nil && item.shownIconsAreCurrent)
    }
}
