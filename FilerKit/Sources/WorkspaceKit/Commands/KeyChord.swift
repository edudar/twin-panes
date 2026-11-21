import AppKit

/// A key plus modifiers, normalized so an `NSEvent` and a menu key equivalent compare
/// equal.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// One character: a lowercase letter/digit/symbol, or an AppKit function-key
    /// character (`NSF3FunctionKey`, `\t`, `\r`, Escape…).
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// F1…F35.
    public static func function(_ number: Int, _ modifiers: Modifiers = []) -> KeyChord {
        precondition((1...35).contains(number))
        let scalar = UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(number - 1))!
        return KeyChord(String(Character(scalar)), modifiers)
    }

    public static let tab = KeyChord("\t")
    public static let escape = KeyChord("\u{1b}")
    public static let returnKey = KeyChord("\r")

    public init?(event: NSEvent) {
        guard event.type == .keyDown, var chars = event.charactersIgnoringModifiers,
            !chars.isEmpty
        else { return nil }
        var modifiers = Modifiers(event.modifierFlags)
        // ⇧Tab arrives as backtab; keep it as Tab + shift.
        if chars == "\u{19}" { chars = "\t" }
        // Shifted letters/symbols arrive already shifted ("A", "{"); the shift is in the
        // character for symbols, so only keep it for letters and special keys.
        if modifiers.contains(.shift), chars.lowercased() == chars,
            !Self.isSpecialKey(chars)
        {
            modifiers.remove(.shift)
        }
        self.init(chars, modifiers)
    }

    /// Menu item representation (`keyEquivalent`, `keyEquivalentModifierMask`).
    public var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        (key, modifiers.eventFlags)
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.displayName(of: key)
    }

    private static func isSpecialKey(_ key: String) -> Bool {
        guard let scalar = key.unicodeScalars.first else { return false }
        return key.unicodeScalars.count == 1
            && (scalar.value < 0x20 || scalar.value == 0x7f
                || (0xF700...0xF8FF).contains(scalar.value))
    }

    private static func displayName(of key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch scalar.value {
        case 0x09: return "Tab"
        case 0x0D: return "↩"
        case 0x1B: return "Esc"
        case UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey):
            return "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
        default: return key.uppercased()
        }
    }
}

extension KeyChord.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
