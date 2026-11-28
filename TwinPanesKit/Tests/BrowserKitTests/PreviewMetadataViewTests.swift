import AppKit
import Darwin
import Foundation
import Testing
import TwinPanesCore

@testable import BrowserKit

@MainActor
@Suite struct PreviewMetadataViewTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PreviewMetadataViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func rowValue(_ label: String, in view: PreviewMetadataView) -> String? {
        view.rows.first { $0.label == label }?.value
    }

    private func renderedStrings(in view: NSView) -> [String] {
        view.subviews.flatMap { subview in
            let own = (subview as? NSTextField).map { [$0.stringValue] } ?? []
            return own + renderedStrings(in: subview)
        }
    }

    @Test func singleFileShowsMetadataRowsPermissionsHardLinksFlagsAndXattrs() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("sample.txt")
            try Data("hello metadata".utf8).write(to: file)
            #expect(chmod(file.path, 0o640) == 0)
            #expect(link(file.path, dir.appendingPathComponent("sample-link.txt").path) == 0)
            #expect(chflags(file.path, UInt32(UF_HIDDEN)) == 0)
            defer { chflags(file.path, 0) }
            let xattrBytes = [UInt8](repeating: 7, count: 5)
            #expect(
                setxattr(file.path, "com.tp.test", xattrBytes, xattrBytes.count, 0, XATTR_NOFOLLOW)
                    == 0)

            let metadata = try FileMetadata.read(url: file)
            let view = PreviewMetadataView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
            view.show(metadata)

            #expect(view.accessibilityIdentifier() == "previewMetadata")
            #expect(view.titleText == "sample.txt")
            #expect(rowValue("Kind", in: view) == metadata.kind)
            #expect(rowValue("Size", in: view) != nil)
            #expect(rowValue("On Disk", in: view) != nil)
            #expect(rowValue("Created", in: view) != nil)
            #expect(rowValue("Modified", in: view) != nil)
            #expect(rowValue("Accessed", in: view) != nil)
            #expect(rowValue("Permissions", in: view) == "rw-r----- (0640)")
            #expect(rowValue("Owner", in: view) == "\(metadata.owner) : \(metadata.group)")
            #expect(rowValue("Hard Links", in: view) == "2")
            #expect(rowValue("Flags", in: view) == "Hidden")
            #expect(view.extendedAttributeRows.contains { $0.label == "com.tp.test" })
            let strings = renderedStrings(in: view)
            #expect(strings.contains("sample.txt"))
            #expect(strings.contains("rw-r----- (0640)"))
            #expect(strings.contains("com.tp.test"))

            view.layoutSubtreeIfNeeded()
            let separator = try #require(findSeparator(in: view))
            #expect(separator.alignmentRect(forFrame: separator.frame).height == 1)
        }
    }

    private func findSeparator(in view: NSView) -> NSBox? {
        if let box = view as? NSBox, box.boxType == .separator { return box }
        for subview in view.subviews {
            if let found = findSeparator(in: subview) { return found }
        }
        return nil
    }

    @Test func symlinkTargetAndExtendedAttributeOverflowIndicator() throws {
        try withTempDir { dir in
            let target = dir.appendingPathComponent("target.bin")
            try Data("abc".utf8).write(to: target)
            for index in 0..<(FileMetadata.maxExtendedAttributes + 2) {
                var byte = UInt8(index)
                let name = String(format: "com.tp.x.%02d", index)
                #expect(setxattr(target.path, name, &byte, 1, 0, XATTR_NOFOLLOW) == 0)
            }
            let linkURL = dir.appendingPathComponent("link.bin")
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)

            let targetMeta = try FileMetadata.read(url: target)
            let linkMeta = try FileMetadata.read(url: linkURL)

            let view = PreviewMetadataView()
            view.show(targetMeta)
            #expect(view.hasMoreExtendedAttributes)
            #expect(renderedStrings(in: view).contains { $0.contains("+ more") })

            view.show(linkMeta)
            #expect(rowValue("Target", in: view) == target.path)
            #expect(!view.hasMoreExtendedAttributes)
        }
    }

    @Test func multiSelectionMessageAndClearStates() {
        let view = PreviewMetadataView()
        view.showMultiSelection(count: 3, totalBytes: 2048)
        #expect(view.titleText == "3 items selected")
        #expect(rowValue("Total Size", in: view) != nil)
        #expect(renderedStrings(in: view).contains("3 items selected"))

        view.showMessage("No Selection")
        #expect(view.titleText == nil)
        #expect(view.rows.isEmpty)
        #expect(view.messageText == "No Selection")
        #expect(renderedStrings(in: view) == ["No Selection"])

        view.clear()
        #expect(view.titleText == nil)
        #expect(view.rows.isEmpty)
        #expect(view.messageText == nil)
        #expect(renderedStrings(in: view).isEmpty)
    }
}
