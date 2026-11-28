import Foundation

/// User-chosen classification override for a file or extension (`docs/plans/M7b.md`, D-b).
public enum PreviewFormatOverride: Equatable, Sendable, RawRepresentable, Codable {
    case structured(StructuredFormat)
    case plainText
    case preview
    case hex

    public var rawValue: String {
        switch self {
        case .structured(let format): format.rawValue
        case .plainText: "plainText"
        case .preview: "preview"
        case .hex: "hex"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "plainText": self = .plainText
        case "preview": self = .preview
        case "hex": self = .hex
        default:
            guard let format = StructuredFormat(rawValue: rawValue) else { return nil }
            self = .structured(format)
        }
    }
}

/// Persists per-extension `PreviewFormatOverride` values in `UserDefaults`, keyed by
/// lowercased extension without a leading dot (`docs/plans/M7b.md`, D-b).
@MainActor
public final class PreviewFormatOverrides {
    private let defaults: UserDefaults
    private let key: String
    private var entries: [String: String]

    public init(
        defaults: UserDefaults = .standard,
        key: String = "PreviewFormatOverrides.byExtension"
    ) {
        self.defaults = defaults
        self.key = key
        self.entries = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    public func override(forExtension ext: String) -> PreviewFormatOverride? {
        let normalized = Self.normalize(ext)
        guard !normalized.isEmpty, let raw = entries[normalized] else { return nil }
        return PreviewFormatOverride(rawValue: raw)
    }

    public func set(_ override: PreviewFormatOverride, forExtension ext: String) {
        let normalized = Self.normalize(ext)
        guard !normalized.isEmpty else { return }
        entries[normalized] = override.rawValue
        defaults.set(entries, forKey: key)
    }

    public func remove(forExtension ext: String) {
        let normalized = Self.normalize(ext)
        guard !normalized.isEmpty, entries.removeValue(forKey: normalized) != nil else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(entries, forKey: key)
        }
    }

    private static func normalize(_ ext: String) -> String {
        String(ext.drop(while: { $0 == "." })).lowercased()
    }
}
