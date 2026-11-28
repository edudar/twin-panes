/// `text` with the characters HTML gives meaning to replaced by entities, safe inside
/// element content and double-quoted attributes.
func escapingHTML(_ text: some StringProtocol) -> String {
    var escaped = ""
    escaped.reserveCapacity(text.utf8.count)
    for character in text {
        switch character {
        case "&": escaped += "&amp;"
        case "<": escaped += "&lt;"
        case ">": escaped += "&gt;"
        case "\"": escaped += "&quot;"
        default: escaped.append(character)
        }
    }
    return escaped
}
