import AppKit
import Foundation
import HexViewKit
import Synchronization
import Testing
import TwinPanesCore

@testable import EditorKit

/// Deterministic `ByteReading` whose first read signals `started` and blocks until
/// `release()` is called, so search cancellation and generation tests need neither 4 GiB
/// sparse files nor arbitrary sleeps.
private final class GatedBytes: ByteReading, Sendable {
    let data: Data
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private let blockedOnce = Atomic(false)

    init(_ data: Data) { self.data = data }

    var length: UInt64 { UInt64(data.count) }

    func waitUntilStarted() { entered.wait() }
    func release() { gate.signal() }
    func waitUntilFinished() { exited.wait() }

    func read(_ range: Range<UInt64>) throws -> Data {
        if blockedOnce.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
        {
            entered.signal()
            gate.wait()
            defer { exited.signal() }
            return data[Int(range.lowerBound)..<Int(range.upperBound)]
        }
        return data[Int(range.lowerBound)..<Int(range.upperBound)]
    }
}

private struct PlainBytes: ByteReading {
    let data: Data
    var length: UInt64 { UInt64(data.count) }
    func read(_ range: Range<UInt64>) throws -> Data {
        data[Int(range.lowerBound)..<Int(range.upperBound)]
    }
}

@MainActor
@Suite struct HexEditorSearchTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorSearchTests-\(UUID().uuidString).bin")

    func makeItem(_ bytes: Data = Data((0..<256).map { UInt8($0) })) throws -> HexEditorItem {
        try bytes.write(to: url)
        return try HexEditorItem(url: url)
    }

    @Test func closingStopsARunningSearch() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let controller = item.controller
        _ = controller.view
        let gated = GatedBytes(Data(count: 64))
        controller.searchSourceOverride = gated

        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "FF"
        controller.findAll()
        #expect(controller.isSearching)

        await Task.detached { gated.waitUntilStarted() }.value
        item.willClose()
        #expect(!controller.isSearching)
        gated.release()
        await Task.detached { gated.waitUntilFinished() }.value
    }

    @Test func aReplacedSearchCannotOverwriteTheNewerResult() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let controller = item.controller
        _ = controller.view
        let gated = GatedBytes(Data(repeating: 0x00, count: 64))
        controller.searchSourceOverride = gated

        controller.editorFind(nil)
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "FF"
        controller.find(.forward)
        await Task.detached { gated.waitUntilStarted() }.value

        // Replace with an instant search that finds 0x41 at offset 0x41.
        controller.searchSourceOverride = nil
        controller.findBar.field.stringValue = "41"
        controller.find(.forward)
        for _ in 0..<200 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(item.hexView.selection.range == 0x41..<0x42)
        #expect(controller.findBar.statusLabel.stringValue.hasPrefix("Found at 0x41"))

        // Unblock the superseded search and verify it cannot clobber the newer result.
        gated.release()
        await Task.detached { gated.waitUntilFinished() }.value
        await Task.yield()
        #expect(item.hexView.selection.range == 0x41..<0x42)
        #expect(controller.findBar.statusLabel.stringValue.hasPrefix("Found at 0x41"))
    }

    @Test func escapeCancelsRunningSearchThenClosesBar() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem()
        let controller = item.controller
        _ = controller.view
        let gated = GatedBytes(Data(count: 64))
        controller.searchSourceOverride = gated

        controller.editorFind(nil)
        #expect(!controller.findBar.isHidden)
        controller.findBar.kind = .hex
        controller.findBar.field.stringValue = "FF"
        controller.find(.forward)
        await Task.detached { gated.waitUntilStarted() }.value

        // First Esc cancels the search but keeps the bar visible.
        controller.editorCloseFind(nil)
        #expect(!controller.isSearching)
        #expect(!controller.findBar.isHidden)
        #expect(controller.findBar.statusLabel.stringValue == "Cancelled")
        gated.release()
        await Task.detached { gated.waitUntilFinished() }.value

        // Second Esc closes the bar.
        controller.editorCloseFind(nil)
        #expect(controller.findBar.isHidden)
    }

    @Test func findNextWorksWhenBarHiddenAndFindAllRevealsBar() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem(Data("ab..ab..ab".utf8))
        let controller = item.controller
        _ = controller.view

        controller.findBar.kind = .utf8
        controller.findBar.field.stringValue = "ab"
        #expect(controller.findBar.isHidden)

        // ⌘G while bar is hidden still searches using the existing pattern.
        controller.find(.forward)
        for _ in 0..<200 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(item.hexView.selection.range == 0..<2)
        #expect(controller.findBar.isHidden)

        // Find All unhides the find bar so progress and match counts are visible.
        controller.findAll()
        for _ in 0..<200 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!controller.findBar.isHidden)
        #expect(item.hexView.highlights == [0..<2, 4..<6, 8..<10])
    }

    @Test func findBarKindsErrorStatusAndUseSelectionCap() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem(Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) }))
        let controller = item.controller
        _ = controller.view

        controller.findBar.field.stringValue = "Hi"
        for kind in FindBarView.Kind.allCases where kind != .hex {
            controller.findBar.kind = kind
            #expect(controller.findBar.ignoreCase.isEnabled)
            #expect((try? controller.findBar.pattern()) != nil)
        }
        controller.findBar.kind = .hex
        #expect(!controller.findBar.ignoreCase.isEnabled)
        controller.findBar.field.stringValue = "ZZ"
        controller.find(.forward)
        #expect(controller.findBar.statusLabel.stringValue.contains("isn't hex"))

        // Use Selection caps at SearchPattern.maxLength bytes.
        item.hexView.select(0..<5000)
        controller.editorUseSelectionForFind(nil)
        #expect(controller.findBar.kind == .hex)
        #expect(try controller.findBar.pattern().count == SearchPattern.maxLength)
    }

    @Test func viewOptionActionsAndMenuValidation() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try makeItem(Data([1, 2, 3, 4]))
        let controller = item.controller
        _ = controller.view

        func menuItem(_ action: Selector, _ value: Any? = nil) -> NSMenuItem {
            let m = NSMenuItem(title: "", action: action, keyEquivalent: "")
            m.representedObject = value
            return m
        }

        let bpr32 = menuItem(#selector(HexEditorViewController.setBytesPerRow(_:)), 32)
        controller.setBytesPerRow(bpr32)
        #expect(item.hexView.options.bytesPerRow == .fixed(32))
        #expect(controller.validateMenuItem(bpr32))
        #expect(bpr32.state == .on)

        let grp4 = menuItem(#selector(HexEditorViewController.setGrouping(_:)), 4)
        controller.setGrouping(grp4)
        #expect(item.hexView.options.grouping == 4)
        #expect(controller.validateMenuItem(grp4) && grp4.state == .on)

        let dec = menuItem(#selector(HexEditorViewController.setOffsetBase(_:)), "decimal")
        controller.setOffsetBase(dec)
        #expect(item.hexView.options.offsetBase == .decimal)
        #expect(controller.validateMenuItem(dec) && dec.state == .on)

        let latin1 = menuItem(#selector(HexEditorViewController.setTextEncoding(_:)), "latin1")
        controller.setTextEncoding(latin1)
        #expect(item.hexView.options.textEncoding == .latin1)
        #expect(controller.validateMenuItem(latin1) && latin1.state == .on)

        let toggle = menuItem(#selector(HexEditorViewController.toggleInspector(_:)))
        #expect(controller.validateMenuItem(toggle) && toggle.title == "Show Inspector")
        controller.toggleInspector(nil)
        #expect(controller.validateMenuItem(toggle) && toggle.title == "Hide Inspector")

        let closeFind = menuItem(#selector(HexEditorViewController.editorCloseFind(_:)))
        #expect(!controller.validateMenuItem(closeFind))
    }
}
