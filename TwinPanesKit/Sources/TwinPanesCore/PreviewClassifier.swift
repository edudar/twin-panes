import UniformTypeIdentifiers

/// How a Quick View tab displays an item (`docs/plans/M7b.md`, D-a).
public enum PreviewMode: String, Equatable, Sendable {
    case pretty, text, preview, hex
}

/// Structured text or data formats supported natively by Quick View (`docs/plans/M7b.md`, D-a).
public enum StructuredFormat: String, CaseIterable, Equatable, Sendable {
    case json, xml, plist, yaml, toml, csv, tsv, properties
}

/// Available modes, default mode, and optional structured format for an item (`docs/plans/M7b.md`, D-a).
public struct PreviewClassification: Equatable, Sendable {
    public let availableModes: [PreviewMode]
    public let defaultMode: PreviewMode
    public let structuredFormat: StructuredFormat?

    public init(
        availableModes: [PreviewMode],
        defaultMode: PreviewMode,
        structuredFormat: StructuredFormat? = nil
    ) {
        self.availableModes = availableModes
        self.defaultMode = defaultMode
        self.structuredFormat = structuredFormat
    }
}

/// Pure, O(1) classifier choosing available and default `PreviewMode`s without touching disk
/// (`docs/plans/M7b.md`, D-a).
public enum PreviewClassifier {
    private static let quickLookTypes: [UTType] = [
        .image, .pdf, .audiovisualContent, .rtf, .rtfd, .html,
        .font, .threeDContent, .webArchive, .calendarEvent, .vCard, .emailMessage,
    ]

    private static let officeTypePrefixes = [
        "com.apple.iwork.", "org.openxmlformats.", "org.oasis-open.opendocument.",
    ]

    private static let legacyOfficeIdentifiers: Set<String> = [
        "com.microsoft.word.doc", "com.microsoft.excel.xls", "com.microsoft.powerpoint.ppt",
    ]

    private static let legacyOfficeTypes: [UTType] =
        legacyOfficeIdentifiers.compactMap { UTType($0) }

    private static let structuredExtensions: [String: StructuredFormat] = [
        "json": .json, "xml": .xml, "plist": .plist,
        "yaml": .yaml, "yml": .yaml, "toml": .toml,
        "csv": .csv, "tsv": .tsv, "properties": .properties,
    ]

    // Check `.propertyList` before `.xml` because `com.apple.xml-property-list` conforms to both.
    private static let structuredTypes: [(UTType, StructuredFormat)] = [
        (.propertyList, .plist), (.json, .json), (.yaml, .yaml),
        (.commaSeparatedText, .csv), (.tabSeparatedText, .tsv), (.xml, .xml),
    ]

    /// Classifies an item into its available preview modes, default mode, and optional
    /// structured format.
    public static func classify(
        type: UTType,
        fileExtension: String = "",
        isDirectory: Bool,
        isPackage: Bool,
        isDataless: Bool = false,
        hasDirtySession: Bool = false,
        override: PreviewFormatOverride? = nil
    ) -> PreviewClassification {
        if isDirectory || isPackage || isDataless {
            return PreviewClassification(availableModes: [.preview], defaultMode: .preview)
        }
        let base =
            override.map(classification(for:))
            ?? autoClassify(type: type, fileExtension: fileExtension)
        guard hasDirtySession else { return base }
        return PreviewClassification(
            availableModes: base.availableModes, defaultMode: .hex,
            structuredFormat: base.structuredFormat)
    }

    private static func classification(
        for override: PreviewFormatOverride
    ) -> PreviewClassification {
        switch override {
        case .structured(let format):
            PreviewClassification(
                availableModes: [.pretty, .text, .hex], defaultMode: .pretty,
                structuredFormat: format)
        case .plainText:
            PreviewClassification(availableModes: [.text, .hex], defaultMode: .text)
        case .preview:
            PreviewClassification(availableModes: [.preview, .hex], defaultMode: .preview)
        case .hex:
            PreviewClassification(availableModes: [.hex], defaultMode: .hex)
        }
    }

    private static func autoClassify(
        type: UTType, fileExtension: String
    ) -> PreviewClassification {
        let ext = String(fileExtension.drop(while: { $0 == "." })).lowercased()
        if let format = structuredExtensions[ext] {
            return PreviewClassification(
                availableModes: [.pretty, .text, .hex], defaultMode: .pretty,
                structuredFormat: format)
        }
        if !type.isDynamic {
            // Check Quick Look types before `.xml` and `.text` so `.svg`, `.rtf`, `.rtfd`,
            // and `.html` keep native Quick Look preview.
            if isQuickLookRenderable(type) {
                return PreviewClassification(
                    availableModes: [.preview, .hex], defaultMode: .preview)
            }
            if let format = structuredTypes.first(where: { type.conforms(to: $0.0) })?.1 {
                return PreviewClassification(
                    availableModes: [.pretty, .text, .hex], defaultMode: .pretty,
                    structuredFormat: format)
            }
            if type.conforms(to: .text) {
                return PreviewClassification(availableModes: [.text, .hex], defaultMode: .text)
            }
        }
        return PreviewClassification(availableModes: [.hex], defaultMode: .hex)
    }

    private static func isQuickLookRenderable(_ type: UTType) -> Bool {
        if quickLookTypes.contains(where: { type.conforms(to: $0) }) { return true }
        let identifier = type.identifier
        if officeTypePrefixes.contains(where: { identifier.hasPrefix($0) }) { return true }
        if legacyOfficeIdentifiers.contains(identifier) { return true }
        return legacyOfficeTypes.contains(where: { type.conforms(to: $0) })
    }
}
