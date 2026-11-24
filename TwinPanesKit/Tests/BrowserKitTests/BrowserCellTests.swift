import AppKit
import CoreText
import Testing
import TwinPanesCore

@testable import BrowserKit

/// Cell text laid out once per text, width and style, and coloured when drawn
/// (docs/plans/M4.md, performance pass, step 4).
@MainActor
@Suite struct BrowserCellTests {
    @Test func aLineIsLaidOutAgainOnlyWhenItsTextWidthOrStyleChange() {
        let cell = FileCell(secondary: false)
        cell.text = "report.txt"
        _ = cell.preparedLine(width: 100, version: 0)
        _ = cell.preparedLine(width: 100, version: 0)
        #expect(cell.lineBuilds == 1)
        _ = cell.preparedLine(width: 50, version: 0)
        #expect(cell.lineBuilds == 2)
        cell.text = "notes.txt"
        _ = cell.preparedLine(width: 50, version: 0)
        #expect(cell.lineBuilds == 3)
        cell.backgroundStyle = .emphasized  // selected: another colour, the same layout
        _ = cell.preparedLine(width: 50, version: 0)
        #expect(cell.lineBuilds == 3)
        _ = cell.preparedLine(width: 50, version: 1)  // a new style
        #expect(cell.lineBuilds == 4)
    }

    @Test func aLongNameIsTruncatedToTheWidth() {
        let cell = FileCell(secondary: false)
        cell.text = String(repeating: "long-name-", count: 20) + "end.txt"
        let full = cell.preparedLine(width: 10_000).width
        let short = cell.preparedLine(width: 80).width
        #expect(short <= 80 && short < full)
    }

    /// The colour comes from the context, so a new appearance needs no new layout.
    @Test func theLineCarriesNoColour() throws {
        let cell = FileCell(secondary: true)
        cell.text = "12 KB"
        let line = cell.preparedLine(width: 100).line
        let runs = try #require(CTLineGetGlyphRuns(line) as? [CTRun])
        let attributes = try #require(runs.first.map { CTRunGetAttributes($0) as NSDictionary })
        #expect(attributes[kCTForegroundColorFromContextAttributeName] as? Bool == true)
        #expect(attributes[kCTForegroundColorAttributeName] == nil)
    }

    /// Ink in the left and right halves of a cell drawn into a bitmap.
    func ink(_ cell: FileCell) throws -> (left: Int, right: Int) {
        cell.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        var (left, right) = (0, 0)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                if x < rep.pixelsWide / 2 { left += 1 } else { right += 1 }
            }
        }
        return (left, right)
    }

    @Test func textIsDrawnOnTheAlignedSide() throws {
        let cell = FileCell(secondary: true)
        cell.text = "1 KB"
        let left = try ink(cell)
        #expect(left.left > 0 && left.right == 0)
        cell.alignment = .right
        let right = try ink(cell)
        #expect(right.right > 0 && right.left == 0)
    }

    @Test func parentCellIsTableCellViewWithImageAndText() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserCellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = dir.appendingPathComponent("defaults").path
        let grants = FolderGrants(defaults: try #require(UserDefaults(suiteName: suite)))
        let item = BrowserItem(folder: dir, grants: grants) { _, _ in }
        defer { item.willClose() }
        let controller = item.controller
        _ = controller.view
        let cell = controller.tableView(
            controller.tableView, viewFor: controller.tableView.tableColumns.first, row: 0)
        let tableCell = try #require(cell as? NSTableCellView)
        #expect(tableCell.textField != nil)
        #expect(tableCell.imageView != nil)
    }

    @Test func rightAlignedNarrowFileCellClampsTextOrigin() throws {
        let cell = FileCell(secondary: false)
        cell.text = "123456789 KB"
        cell.alignment = .right
        cell.frame = NSRect(x: 0, y: 0, width: 30, height: 20)
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / cell.bounds.width
        let iconRegionMaxX = Int((22 * scale).rounded(.down))
        var iconAreaInk = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<iconRegionMaxX
            where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                iconAreaInk += 1
            }
        }
        #expect(iconAreaInk == 0)
    }
}
