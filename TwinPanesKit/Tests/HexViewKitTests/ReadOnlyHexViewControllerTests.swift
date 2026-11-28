import AppKit
import Darwin
import Foundation
import Synchronization
import Testing
import TwinPanesCore
import WorkspaceKit

@testable import HexViewKit

private final class FakeCloudDownloads: CloudDownloads {
    private struct State {
        var datalessPaths: Set<String> = []
        var startDownloadCalls: [URL] = []
        var startDownloadError: (any Error)?
    }
    private let state = Mutex(State())
    func markDataless(_ url: URL) {
        state.withLock { _ = $0.datalessPaths.insert(url.standardizedFileURL.path) }
    }
    func setStartDownloadError(_ error: (any Error)?) {
        state.withLock { $0.startDownloadError = error }
    }
    func isDataless(_ url: URL) -> Bool {
        state.withLock { $0.datalessPaths.contains(url.standardizedFileURL.path) }
    }
    func startDownload(_ url: URL) throws {
        let error: (any Error)? = state.withLock {
            $0.startDownloadCalls.append(url)
            return $0.startDownloadError
        }
        if let error { throw error }
    }
    var startDownloadCalls: [URL] { state.withLock(\.startDownloadCalls) }
}

private struct LocalFileSystem: FileSystem {
    private let real = RealFileSystem()
    func replacementDirectory(for url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func clone(_ source: URL, to destination: URL) throws {
        try real.clone(source, to: destination)
    }
    func copy(_ source: URL, to destination: URL) throws { try real.copy(source, to: destination) }
    func availableCapacity(for url: URL) -> UInt64? { real.availableCapacity(for: url) }
    func openForWriting(_ url: URL) throws -> Int32 { try real.openForWriting(url) }
    func create(_ url: URL) throws -> Int32 { try real.create(url) }
    func move(_ source: URL, to destination: URL) throws { try real.move(source, to: destination) }
    func write(_ data: Data, to descriptor: Int32, at offset: UInt64, path: String) throws {
        try real.write(data, to: descriptor, at: offset, path: path)
    }
    func truncate(_ descriptor: Int32, to length: UInt64, path: String) throws {
        try real.truncate(descriptor, to: length, path: path)
    }
    func fullSync(_ descriptor: Int32, path: String) throws {
        try real.fullSync(descriptor, path: path)
    }
    func close(_ descriptor: Int32) { real.close(descriptor) }
    func replaceItem(at url: URL, with staged: URL) throws {
        guard rename(staged.path, url.path) == 0 else {
            throw FileSystemError("replace", url.path, errno: errno)
        }
    }
    func removeItem(at url: URL) { real.removeItem(at: url) }
}

@MainActor
@Suite struct ReadOnlyHexViewControllerTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadOnlyHexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func awaitState(
        on viewer: ReadOnlyHexViewController,
        until condition: @escaping @MainActor () -> Bool
    ) async {
        if condition() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let previous = viewer.onStateChange
            viewer.onStateChange = {
                previous?()
                if condition() {
                    viewer.onStateChange = previous
                    continuation.resume()
                }
            }
        }
    }

    private func findView(in root: NSView, identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = findView(in: child, identifier: identifier) { return found }
        }
        return nil
    }

    private func findButton(in root: NSView, title: String) -> NSButton? {
        if let button = root as? NSButton, button.title == title { return button }
        for child in root.subviews {
            if let found = findButton(in: child, title: title) { return found }
        }
        return nil
    }

    private func openFileDescriptorPaths(under directory: URL) -> [String] {
        let prefix = directory.standardizedFileURL.resolvingSymlinksInPath().path
        var matches: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in Int32(0)..<Int32(min(Int(getdtablesize()), 4096)) {
            guard fcntl(fd, F_GETFD) != -1, fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
            let path = buffer.withUnsafeBufferPointer {
                $0.baseAddress.map { String(cString: $0) } ?? ""
            }
            let resolved = URL(fileURLWithPath: path).standardizedFileURL
                .resolvingSymlinksInPath().path
            if resolved.hasPrefix(prefix) { matches.append(resolved) }
        }
        return matches
    }

    @Test func factoryConfiguresReadOnlyFontsAndDefaultOptions() {
        let sessions = SessionRegistry()
        let factory = SessionHexViewerFactory(sessions: sessions)

        let regular = factory.makeHexViewer(style: .regular) as? ReadOnlyHexViewController
        let compact = factory.makeHexViewer(style: .compact) as? ReadOnlyHexViewController

        #expect(regular != nil)
        #expect(compact != nil)
        #expect(regular?.hexView.options == HexViewOptions())
        #expect(compact?.hexView.options == HexViewOptions())
        #expect(regular?.hexView.font.pointSize == 13)
        #expect(compact?.hexView.font.pointSize == 11)
        #expect(regular?.hexView.accessibilityIdentifier() == "readOnlyHexView")
        #expect(
            regular?.hexView.delegate?.hexView(
                regular!.hexView, overwrite: Data([0xAA]), at: 0, column: .hex, cursorAfter: 0)
                == false)
    }

    @Test func viewOptionActionsValidateAndSyncAcrossViewers() {
        let sessions = SessionRegistry()
        let preferences = HexViewPreferences()
        let factory = SessionHexViewerFactory(sessions: sessions, preferences: preferences)
        let first = factory.makeHexViewer(style: .regular) as! ReadOnlyHexViewController
        let second = factory.makeHexViewer(style: .regular) as! ReadOnlyHexViewController
        _ = (first.view, second.view)

        func menuItem(_ action: Selector, _ value: Any) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.representedObject = value
            return item
        }

        let bpr32 = menuItem(#selector(ReadOnlyHexViewController.setBytesPerRow(_:)), 32)
        let fit = menuItem(#selector(ReadOnlyHexViewController.setBytesPerRow(_:)), 0)
        let grp4 = menuItem(#selector(ReadOnlyHexViewController.setGrouping(_:)), 4)
        let dec = menuItem(#selector(ReadOnlyHexViewController.setOffsetBase(_:)), "decimal")
        let latin1 = menuItem(#selector(ReadOnlyHexViewController.setTextEncoding(_:)), "latin1")

        first.setBytesPerRow(bpr32)
        #expect(first.hexView.options.bytesPerRow == .fixed(32))
        #expect(first.validateMenuItem(bpr32) && bpr32.state == .on && fit.state == .off)

        first.setBytesPerRow(fit)
        first.setGrouping(grp4)
        first.setOffsetBase(dec)
        first.setTextEncoding(latin1)
        let expected = HexViewOptions(
            bytesPerRow: .autoFit, grouping: 4, offsetBase: .decimal, textEncoding: .latin1)
        #expect(first.hexView.options == expected && second.hexView.options == expected)
        #expect(preferences.options == expected)
        for item in [fit, grp4, dec, latin1] {
            #expect(first.validateMenuItem(item) && item.state == .on)
        }

        first.hexView.isHidden = true
        for item in [bpr32, grp4, dec, latin1] { #expect(!first.validateMenuItem(item)) }
    }

    @Test func retargetingAcrossThousandFilesCreatesZeroSessionsAndLeaksNoFDs() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var urls: [URL] = []
        urls.reserveCapacity(1000)
        for i in 0..<1000 {
            let file = dir.appendingPathComponent("file-\(i).bin")
            try Data([UInt8(truncatingIfNeeded: i), 0x42]).write(to: file)
            urls.append(file)
        }

        let sessions = SessionRegistry()
        let cloud = FakeCloudDownloads()
        let factory = SessionHexViewerFactory(sessions: sessions, cloudDownloads: cloud)
        let viewer = try #require(
            factory.makeHexViewer(style: .regular) as? ReadOnlyHexViewController)
        _ = viewer.view

        for url in urls {
            viewer.show(url, scope: nil)
        }

        await awaitState(on: viewer) { viewer.length == 2 }
        #expect(try viewer.read(0..<2) == Data([UInt8(truncatingIfNeeded: 999), 0x42]))
        #expect(sessions.sessions.isEmpty)

        viewer.show(nil, scope: nil)
        #expect(viewer.length == 0)
        #expect(openFileDescriptorPaths(under: dir).isEmpty)
    }

    @Test func liveDirtySessionUpdatesOnEditSaveAndClose() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("live.bin")
        try Data([0x10, 0x20, 0x30, 0x40]).write(to: file)

        let sessions = SessionRegistry()
        let session = try EditorSession(url: file, saver: Saver(fileSystem: LocalFileSystem()))
        sessions.adopt(session)
        try session.overwrite(
            Data([0xDE, 0xAD]), at: 1, selectionBefore: 1..<2, selectionAfter: 2..<3)

        let viewer = ReadOnlyHexViewController(style: .compact, sessions: sessions)
        _ = viewer.view
        var stateChanges = 0
        viewer.onStateChange = { stateChanges += 1 }

        viewer.show(file, scope: nil)
        #expect(viewer.showsUnsavedEdits)
        #expect(try viewer.read(0..<4) == Data([0x10, 0xDE, 0xAD, 0x40]))
        #expect(viewer.modifiedRanges(in: 0..<4) == [1..<3])
        #expect(stateChanges >= 1)

        try session.overwrite(
            Data([0xBE]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        #expect(try viewer.read(0..<4) == Data([0xBE, 0xDE, 0xAD, 0x40]))
        #expect(viewer.modifiedRanges(in: 0..<4) == [0..<3])

        try await session.save()
        #expect(!viewer.showsUnsavedEdits)
        #expect(try Data(contentsOf: file) == Data([0xBE, 0xDE, 0xAD, 0x40]))

        // Write different bytes directly on disk, then close session: viewer must reload disk bytes.
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: file)
        session.close()
        await awaitState(on: viewer) {
            (try? viewer.read(0..<4)) == Data([0x01, 0x02, 0x03, 0x04])
        }
        #expect(!viewer.showsUnsavedEdits)
        #expect(viewer.modifiedRanges(in: 0..<4).isEmpty)
    }

    @Test func newlyOpenedSessionOnShownFileAttachesLive() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("attach.bin")
        try Data([0xAA, 0xBB, 0xCC, 0xDD]).write(to: file)

        let sessions = SessionRegistry()
        let viewer = ReadOnlyHexViewController(style: .regular, sessions: sessions)
        _ = viewer.view
        viewer.show(file, scope: nil)

        await awaitState(on: viewer) { viewer.length == 4 }
        #expect(!viewer.showsUnsavedEdits)

        let (session, _) = try sessions.open(file)
        try session.overwrite(
            Data([0xFF]), at: 2, selectionBefore: 2..<3, selectionAfter: 3..<4)

        #expect(viewer.showsUnsavedEdits)
        #expect(try viewer.read(0..<4) == Data([0xAA, 0xBB, 0xFF, 0xDD]))
        #expect(viewer.modifiedRanges(in: 0..<4) == [2..<3])
    }

    @Test func datalessFileShowsPlaceholderAndDownloadsOnlyOnClick() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cloud.bin")
        try Data([0x01, 0x02]).write(to: file)

        let sessions = SessionRegistry()
        let cloud = FakeCloudDownloads()
        cloud.markDataless(file)

        let viewer = ReadOnlyHexViewController(
            style: .regular, sessions: sessions, cloudDownloads: cloud)
        let root = viewer.view
        viewer.show(file, scope: nil)

        await awaitState(on: viewer) {
            guard let label = findView(in: root, identifier: "hexPlaceholder") as? NSTextField
            else { return false }
            return !label.isHiddenOrHasHiddenAncestor
                && label.stringValue == "This file is in iCloud and not downloaded."
        }

        #expect(viewer.hexView.isHidden)
        #expect(viewer.length == 0)
        #expect(cloud.startDownloadCalls.isEmpty)

        let button = try #require(findButton(in: root, title: "Download"))
        #expect(!button.isHidden)
        button.performClick(nil)

        await awaitState(on: viewer) { !cloud.startDownloadCalls.isEmpty }
        #expect(cloud.startDownloadCalls == [file])
    }

    @Test func folderAndMissingFileShowPlaceholder() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessions = SessionRegistry()
        let viewer = ReadOnlyHexViewController(style: .regular, sessions: sessions)
        let root = viewer.view

        viewer.show(dir, scope: nil)
        await awaitState(on: viewer) {
            guard let label = findView(in: root, identifier: "hexPlaceholder") as? NSTextField
            else { return false }
            return !label.isHiddenOrHasHiddenAncestor && !label.stringValue.isEmpty
        }
        let folderLabel = try #require(
            findView(in: root, identifier: "hexPlaceholder") as? NSTextField)
        let folderMessage = folderLabel.stringValue
        #expect(folderLabel.textColor == .secondaryLabelColor)
        #expect(viewer.hexView.isHidden)
        #expect(findButton(in: root, title: "Download")?.isHiddenOrHasHiddenAncestor != false)

        let missing = dir.appendingPathComponent("does-not-exist.bin")
        viewer.show(missing, scope: nil)
        await awaitState(on: viewer) {
            guard let label = findView(in: root, identifier: "hexPlaceholder") as? NSTextField
            else { return false }
            return !label.isHiddenOrHasHiddenAncestor && label.stringValue != folderMessage
        }
        #expect(viewer.hexView.isHidden)
    }

    @Test func readForCopyReadsLargeSelectionOffMainThreadWithoutBreaking() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large.bin")
        let count = 300 * 1024
        let payload = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: file)

        let sessions = SessionRegistry()
        let viewer = ReadOnlyHexViewController(style: .regular, sessions: sessions)
        viewer.show(file, scope: nil)
        await awaitState(on: viewer) { viewer.length == UInt64(count) }

        let copied: Data = try await withCheckedThrowingContinuation { continuation in
            viewer.readForCopy(0..<UInt64(count)) { result in
                continuation.resume(with: result)
            }
        }
        #expect(copied == payload)
    }

    @Test func showAfterSessionClosedWhileRetainedReloadsDiskBytes() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("retained-close.bin")
        try Data([0x10, 0x20, 0x30, 0x40]).write(to: file)

        let sessions = SessionRegistry()
        let session = try EditorSession(url: file, saver: Saver(fileSystem: LocalFileSystem()))
        sessions.adopt(session)
        try session.overwrite(
            Data([0xDE, 0xAD]), at: 1, selectionBefore: 1..<2, selectionAfter: 2..<3)

        let viewer = ReadOnlyHexViewController(style: .regular, sessions: sessions)
        _ = viewer.view
        viewer.show(file, scope: nil)
        #expect(viewer.showsUnsavedEdits)
        #expect(try viewer.read(0..<4) == Data([0x10, 0xDE, 0xAD, 0x40]))

        viewer.show(nil, scope: nil)
        try Data([0x55, 0x66, 0x77, 0x88]).write(to: file)
        session.close()

        viewer.show(file, scope: nil)
        await awaitState(on: viewer) {
            (try? viewer.read(0..<4)) == Data([0x55, 0x66, 0x77, 0x88])
        }
        #expect(!viewer.showsUnsavedEdits)
        #expect(viewer.modifiedRanges(in: 0..<4).isEmpty)
        withExtendedLifetime(session) {}
    }

    @Test func sessionRevertAndSaveAsUpdateReadOnlyViewer() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file1 = dir.appendingPathComponent("original.bin")
        let file2 = dir.appendingPathComponent("saved-as.bin")
        try Data([0x10, 0x20, 0x30, 0x40]).write(to: file1)

        let sessions = SessionRegistry()
        let session = try EditorSession(url: file1, saver: Saver(fileSystem: LocalFileSystem()))
        sessions.adopt(session)
        try session.overwrite(
            Data([0xDE, 0xAD]), at: 1, selectionBefore: 1..<2, selectionAfter: 2..<3)

        let viewer = ReadOnlyHexViewController(style: .regular, sessions: sessions)
        _ = viewer.view
        viewer.show(file1, scope: nil)
        #expect(viewer.showsUnsavedEdits)
        #expect(viewer.modifiedRanges(in: 0..<4) == [1..<3])

        session.revert()
        #expect(!viewer.showsUnsavedEdits)
        #expect(viewer.modifiedRanges(in: 0..<4).isEmpty)
        #expect(try viewer.read(0..<4) == Data([0x10, 0x20, 0x30, 0x40]))

        try session.overwrite(
            Data([0xAA, 0xBB]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        #expect(viewer.showsUnsavedEdits)
        try await session.saveAs(to: file2)

        await awaitState(on: viewer) {
            (try? viewer.read(0..<4)) == Data([0x10, 0x20, 0x30, 0x40])
        }
        #expect(!viewer.showsUnsavedEdits)
        #expect(viewer.modifiedRanges(in: 0..<4).isEmpty)

        try session.overwrite(
            Data([0xFF]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        #expect(!viewer.showsUnsavedEdits)
        #expect(try viewer.read(0..<4) == Data([0x10, 0x20, 0x30, 0x40]))
    }

    @Test func downloadErrorDisplaysLocalizedDescriptionAndRemainsRetryable() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("retry.bin")
        try Data([0x01, 0x02]).write(to: file)

        let sessions = SessionRegistry()
        let cloud = FakeCloudDownloads()
        cloud.markDataless(file)
        cloud.setStartDownloadError(
            NSError(
                domain: "TestCloud", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Network offline"]))

        let viewer = ReadOnlyHexViewController(
            style: .regular, sessions: sessions, cloudDownloads: cloud)
        let root = viewer.view
        viewer.show(file, scope: nil)

        await awaitState(on: viewer) {
            guard let label = findView(in: root, identifier: "hexPlaceholder") as? NSTextField
            else { return false }
            return !label.isHiddenOrHasHiddenAncestor
                && label.stringValue == "This file is in iCloud and not downloaded."
        }

        let button = try #require(findButton(in: root, title: "Download"))
        let label = try #require(findView(in: root, identifier: "hexPlaceholder") as? NSTextField)
        button.performClick(nil)

        await awaitState(on: viewer) {
            !cloud.startDownloadCalls.isEmpty
                && label.stringValue != "This file is in iCloud and not downloaded."
        }
        #expect(label.stringValue == "Network offline")
        #expect(!button.isHidden)
        try #require(button.isEnabled)

        cloud.setStartDownloadError(nil)
        button.performClick(nil)
        await awaitState(on: viewer) {
            cloud.startDownloadCalls.count == 2 && label.stringValue != "Network offline"
        }
        #expect(label.stringValue == "Downloading from iCloud…")
        #expect(button.isHidden)
    }

    @Test func readOnlyRejectsInsertTextAndDeleteBackward() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("readonly.bin")
        try Data([0x10, 0x20, 0x30, 0x40]).write(to: file)

        let sessions = SessionRegistry()
        let viewer = ReadOnlyHexViewController(style: .regular, sessions: sessions)
        _ = viewer.view
        viewer.show(file, scope: nil)
        await awaitState(on: viewer) { viewer.length == 4 }

        viewer.hexView.insertText("FF")
        viewer.hexView.deleteBackward(nil)
        #expect(try viewer.read(0..<4) == Data([0x10, 0x20, 0x30, 0x40]))
        #expect(!viewer.showsUnsavedEdits)

        let (session, _) = try sessions.open(file)
        viewer.hexView.insertText("AA")
        viewer.hexView.deleteBackward(nil)
        #expect(!session.isDirty)
        #expect(!viewer.showsUnsavedEdits)
        #expect(try viewer.read(0..<4) == Data([0x10, 0x20, 0x30, 0x40]))
    }

    @Test func retargetDoesNotEagerlyResetHexViewOrFlickerPlaceholder() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file1 = dir.appendingPathComponent("one.bin")
        let file2 = dir.appendingPathComponent("two.bin")
        let missing = dir.appendingPathComponent("missing.bin")
        try Data([0x10, 0x20, 0x30, 0x40]).write(to: file1)
        try Data([0xAA, 0xBB]).write(to: file2)

        let sessions = SessionRegistry()
        let viewer = ReadOnlyHexViewController(style: .regular, sessions: sessions)
        let root = viewer.view

        viewer.show(file1, scope: nil)
        await awaitState(on: viewer) { viewer.length == 4 }
        #expect(viewer.hexView.layout.length == 4)

        viewer.show(file2, scope: nil)
        #expect(viewer.hexView.layout.length == 4)
        await awaitState(on: viewer) { viewer.length == 2 }
        #expect(viewer.hexView.layout.length == 2)
        #expect(try viewer.read(0..<2) == Data([0xAA, 0xBB]))

        viewer.show(missing, scope: nil)
        await awaitState(on: viewer) {
            guard let label = findView(in: root, identifier: "hexPlaceholder") as? NSTextField
            else { return false }
            return !label.isHiddenOrHasHiddenAncestor && !label.stringValue.isEmpty
        }

        let label = try #require(findView(in: root, identifier: "hexPlaceholder") as? NSTextField)
        viewer.show(file1, scope: nil)
        #expect(viewer.hexView.isHidden)
        #expect(!label.isHiddenOrHasHiddenAncestor)

        await awaitState(on: viewer) { viewer.length == 4 }
        #expect(!viewer.hexView.isHidden)
        #expect(viewer.hexView.layout.length == 4)

        viewer.show(nil, scope: nil)
        #expect(!viewer.hexView.isHidden)
        #expect(viewer.hexView.layout.length == 0)

        let session = try EditorSession(url: file1, saver: Saver(fileSystem: LocalFileSystem()))
        sessions.adopt(session)
        try session.overwrite(
            Data([0xFF]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        viewer.show(file1, scope: nil)
        #expect(viewer.showsUnsavedEdits)

        var stateChanges = 0
        viewer.onStateChange = { stateChanges += 1 }
        viewer.show(file2, scope: nil)
        #expect(!viewer.showsUnsavedEdits)
        #expect(stateChanges == 1)
        await awaitState(on: viewer) { viewer.length == 2 }
        #expect(stateChanges == 2)
    }
}
