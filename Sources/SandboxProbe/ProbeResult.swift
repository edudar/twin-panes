import Foundation

/// Outcome of one probe step.
public enum ProbeOutcome: Sendable, Equatable {
    case ok(String)
    case failed(String)
    case skipped(String)

    public var symbol: String {
        switch self {
        case .ok: return "✅"
        case .failed: return "❌"
        case .skipped: return "➖"
        }
    }

    public var detail: String {
        switch self {
        case .ok(let text), .failed(let text), .skipped(let text): return text
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

public struct ProbeResult: Sendable, Equatable {
    public let name: String
    public let outcome: ProbeOutcome
}
