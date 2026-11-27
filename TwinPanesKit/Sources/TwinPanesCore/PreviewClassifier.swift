import UniformTypeIdentifiers

/// How a preview area or Quick View tab displays an item (`docs/plans/M7.md`, D-c).
public enum PreviewMode: String, Equatable, Sendable {
    case quickLook
    case hex
}

/// Chooses the default `PreviewMode` for an item from its type and state without
/// touching disk (`docs/plans/M7.md`, D-c).
public enum PreviewClassifier {
    private static let quickLookTypes: [UTType] = [
        .image, .pdf, .audiovisualContent, .text, .propertyList,
        .rtf, .rtfd, .font, .threeDContent, .webArchive,
        .calendarEvent, .vCard, .emailMessage,
    ]

    private static let officeTypePrefixes = [
        "com.apple.iwork.",
        "org.openxmlformats.",
        "org.oasis-open.opendocument.",
    ]

    private static let legacyOfficeIdentifiers: Set<String> = [
        "com.microsoft.word.doc",
        "com.microsoft.excel.xls",
        "com.microsoft.powerpoint.ppt",
    ]

    private static let legacyOfficeTypes: [UTType] =
        legacyOfficeIdentifiers.compactMap { UTType($0) }

    /// Returns `.quickLook` for folders, packages, dataless iCloud placeholders, and
    /// Quick Look-renderable types; returns `.hex` when a dirty `EditorSession` is open
    /// on a regular file or for binary/unknown types.
    public static func defaultMode(
        for type: UTType,
        isDirectory: Bool,
        isPackage: Bool,
        isDataless: Bool = false,
        hasDirtySession: Bool = false
    ) -> PreviewMode {
        if isDirectory || isPackage || isDataless { return .quickLook }
        if hasDirtySession { return .hex }
        if type.isDynamic { return .hex }
        if isQuickLookRenderable(type) { return .quickLook }
        return .hex
    }

    private static func isQuickLookRenderable(_ type: UTType) -> Bool {
        if quickLookTypes.contains(where: { type.conforms(to: $0) }) { return true }
        let identifier = type.identifier
        if officeTypePrefixes.contains(where: { identifier.hasPrefix($0) }) { return true }
        if legacyOfficeIdentifiers.contains(identifier) { return true }
        return legacyOfficeTypes.contains(where: { type.conforms(to: $0) })
    }
}
