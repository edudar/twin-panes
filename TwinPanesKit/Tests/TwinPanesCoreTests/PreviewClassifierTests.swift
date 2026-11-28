import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TwinPanesCore

@MainActor
@Suite struct PreviewClassifierTests {
    private static func classify(
        _ type: UTType, ext: String = "", isDirectory: Bool = false, isPackage: Bool = false,
        isDataless: Bool = false, hasDirtySession: Bool = false,
        override: PreviewFormatOverride? = nil
    ) -> PreviewClassification {
        PreviewClassifier.classify(
            type: type, fileExtension: ext, isDirectory: isDirectory, isPackage: isPackage,
            isDataless: isDataless, hasDirtySession: hasDirtySession, override: override)
    }

    @Test func structuredFormatsByTypeAndExtension() throws {
        let byType: [(UTType, StructuredFormat)] = [
            (.json, .json), (.xml, .xml), (.propertyList, .plist), (.xmlPropertyList, .plist),
            (.binaryPropertyList, .plist), (.yaml, .yaml), (.commaSeparatedText, .csv),
            (.tabSeparatedText, .tsv),
        ]
        for (type, format) in byType {
            #expect(
                Self.classify(type)
                    == PreviewClassification(
                        availableModes: [.pretty, .text, .hex], defaultMode: .pretty,
                        structuredFormat: format),
                "Expected \(format) for \(type.identifier)")
        }

        let dynamic = try #require(UTType(filenameExtension: "myweirdext99"))
        let byExt: [(String, StructuredFormat)] = [
            ("json", .json), ("XML", .xml), (".plist", .plist), ("yaml", .yaml), ("yml", .yaml),
            ("toml", .toml), ("csv", .csv), ("tsv", .tsv), ("properties", .properties),
        ]
        for (ext, format) in byExt {
            #expect(
                Self.classify(dynamic, ext: ext)
                    == PreviewClassification(
                        availableModes: [.pretty, .text, .hex], defaultMode: .pretty,
                        structuredFormat: format),
                "Expected \(format) for .\(ext)")
        }
    }

    @Test func quickLookPreviewableTypesBeforePlainText() {
        let types: [UTType] = [
            .image, .png, .jpeg, .svg, .pdf, .audiovisualContent, .mp3, .mpeg4Movie,
            .rtf, .rtfd, .html, .font, .threeDContent, .webArchive, .calendarEvent,
            .vCard, .emailMessage,
        ]
        let expected = PreviewClassification(
            availableModes: [.preview, .hex], defaultMode: .preview)
        for type in types {
            #expect(Self.classify(type) == expected, "Expected .preview for \(type.identifier)")
        }
    }

    @Test func officeIWorkAndOpenDocumentTypes() {
        let identifiers = [
            "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.sffnumbers",
            "com.apple.iwork.keynote.sffkey", "org.openxmlformats.wordprocessingml.document",
            "org.openxmlformats.spreadsheetml.sheet",
            "org.openxmlformats.presentationml.presentation",
            "com.microsoft.word.doc", "com.microsoft.excel.xls", "com.microsoft.powerpoint.ppt",
            "org.oasis-open.opendocument.text", "org.oasis-open.opendocument.spreadsheet",
            "org.oasis-open.opendocument.presentation",
        ]
        let expected = PreviewClassification(
            availableModes: [.preview, .hex], defaultMode: .preview)
        for identifier in identifiers {
            let type = UTType(identifier) ?? UTType(importedAs: identifier)
            #expect(Self.classify(type) == expected, "Expected .preview for \(identifier)")
        }
    }

    @Test func plainTextBinaryAndContainerClassifications() throws {
        let textExpected = PreviewClassification(availableModes: [.text, .hex], defaultMode: .text)
        for type in [UTType.text, .plainText, .sourceCode, .swiftSource] {
            #expect(Self.classify(type) == textExpected)
        }

        let dynamic = try #require(UTType(filenameExtension: "myweirdbin123"))
        let hexExpected = PreviewClassification(availableModes: [.hex], defaultMode: .hex)
        for type in [
            UTType.data, .executable, .unixExecutable, .archive, .zip, .diskImage,
            .item, .content, dynamic,
        ] {
            #expect(Self.classify(type) == hexExpected)
        }

        let container = PreviewClassification(availableModes: [.preview], defaultMode: .preview)
        #expect(Self.classify(.data, isDirectory: true) == container)
        #expect(Self.classify(.data, isDirectory: true, hasDirtySession: true) == container)
        #expect(Self.classify(.data, isPackage: true, override: .hex) == container)
        #expect(Self.classify(.image, isDataless: true, hasDirtySession: true) == container)
    }

    @Test func dirtySessionAndOverrides() {
        #expect(
            Self.classify(.json, hasDirtySession: true)
                == PreviewClassification(
                    availableModes: [.pretty, .text, .hex], defaultMode: .hex,
                    structuredFormat: .json))
        #expect(
            Self.classify(.image, hasDirtySession: true)
                == PreviewClassification(availableModes: [.preview, .hex], defaultMode: .hex))
        #expect(
            Self.classify(.plainText, hasDirtySession: true)
                == PreviewClassification(availableModes: [.text, .hex], defaultMode: .hex))
        #expect(
            Self.classify(.data, ext: "geojson", override: .structured(.json))
                == PreviewClassification(
                    availableModes: [.pretty, .text, .hex], defaultMode: .pretty,
                    structuredFormat: .json))
        #expect(
            Self.classify(.data, ext: "env", override: .plainText)
                == PreviewClassification(availableModes: [.text, .hex], defaultMode: .text))
        #expect(
            Self.classify(.data, ext: "custom", override: .preview)
                == PreviewClassification(availableModes: [.preview, .hex], defaultMode: .preview))
        #expect(
            Self.classify(.json, ext: "json", override: .hex)
                == PreviewClassification(availableModes: [.hex], defaultMode: .hex))
        #expect(
            Self.classify(
                .data, ext: "geojson", hasDirtySession: true, override: .structured(.json))
                == PreviewClassification(
                    availableModes: [.pretty, .text, .hex], defaultMode: .hex,
                    structuredFormat: .json))
    }

    @Test func closedEventFiresOnCloseAndNotOnReloads() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewClassifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("file.bin")
        try Data((0..<32).map { UInt8($0) }).write(to: file)
        let root = dir.appendingPathComponent("Sessions")

        final class Recorder {
            var changes: [EditorSession.Change] = []
            let reloadSignal = SearchSignal()
        }

        // Clean outside reload emits .edited, never .closed.
        let clean = try EditorSession(url: file, sessionsRoot: root)
        clean.startWatching()
        defer {
            clean.stopWatching()
            clean.close()
        }
        let cleanRecorder = Recorder()
        clean.observe(cleanRecorder) { change in
            cleanRecorder.changes.append(change)
            if change == .edited { cleanRecorder.reloadSignal.signal() }
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 0x33, count: 32))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
        await cleanRecorder.reloadSignal.wait()
        #expect(!cleanRecorder.changes.contains(.closed))
        clean.stopWatching()
        clean.close()
        #expect(cleanRecorder.changes.last == .closed)

        // Dirty reloadDiscardingEdits deletes the folder and emits .edited, not .closed.
        let dirty = try EditorSession(url: file, sessionsRoot: root)
        let dirtyRecorder = Recorder()
        dirty.observe(dirtyRecorder) { dirtyRecorder.changes.append($0) }
        try dirty.overwrite(
            Data([0xAA]), at: 0, selectionBefore: 0..<1, selectionAfter: 0..<1)
        let made = try #require(dirty.folder)
        try dirty.reloadDiscardingEdits()
        #expect(!FileManager.default.fileExists(atPath: made.url.path))
        #expect(!dirtyRecorder.changes.contains(.closed))
        #expect(dirtyRecorder.changes.contains(.edited))

        dirty.close()
        #expect(dirtyRecorder.changes.last == .closed)
    }

    @Test func sessionRegistryObserveFiresOnOpenAndAdoptAndPrunesDeadOwners() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRegistryObserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func makeFile(_ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data([1, 2, 3, 4]).write(to: url)
            return url
        }

        final class ObserverOwner {}

        let a = try makeFile("a.bin")
        let b = try makeFile("b.bin")
        let c = try makeFile("c.bin")

        let registry = SessionRegistry()
        var owner: ObserverOwner? = ObserverOwner()
        var observed: [EditorSession] = []
        registry.observe(owner!) { observed.append($0) }

        let permanent = ObserverOwner()
        var permanentCount = 0
        registry.observe(permanent) { _ in permanentCount += 1 }

        let (opened, isNew) = try registry.open(a)
        #expect(isNew && observed.count == 1 && observed[0] === opened)

        // Opening an already-registered file does not notify again.
        let (again, againIsNew) = try registry.open(a)
        #expect(!againIsNew && again === opened && observed.count == 1)

        // Adopting a session for a new file notifies; adopting over an existing one does not.
        let recoveredB = try EditorSession(url: b)
        registry.adopt(recoveredB)
        #expect(observed.count == 2 && observed[1] === recoveredB)

        let duplicateA = try EditorSession(url: a)
        registry.adopt(duplicateA)
        #expect(observed.count == 2 && permanentCount == 2)

        // Dropping owner stops future notifications and prunes the dead entry.
        owner = nil
        _ = try registry.open(c)
        #expect(observed.count == 2 && permanentCount == 3)
    }
}
