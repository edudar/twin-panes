/// Parses what people type into Go to Offset.
///
/// Accepted: decimal (`4096`), hex with a prefix or suffix (`0x1000`, `$1000`, `1000h`),
/// and bare hex that contains a letter (`1F00`). Underscores, spaces and commas are
/// ignored. A leading `+` or `-` makes it relative to `current`.
public enum HexOffsetParser {
    public static func parse(_ input: String, current: UInt64 = 0) -> UInt64? {
        var text = input.filter { !" _,".contains($0) }.lowercased()
        var sign: Int = 0
        if text.hasPrefix("+") {
            sign = 1
            text.removeFirst()
        } else if text.hasPrefix("-") {
            sign = -1
            text.removeFirst()
        }
        guard let value = number(text) else { return nil }
        switch sign {
        case 1: return current.addingReportingOverflow(value).overflow ? nil : current + value
        case -1: return current >= value ? current - value : 0
        default: return value
        }
    }

    private static func number(_ text: String) -> UInt64? {
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        if text.hasPrefix("$") { return UInt64(text.dropFirst(), radix: 16) }
        if text.hasSuffix("h") { return UInt64(text.dropLast(), radix: 16) }
        if text.contains(where: { ("a"..."f").contains($0) }) { return UInt64(text, radix: 16) }
        return UInt64(text, radix: 10)
    }
}
