// FilerCore: the UI-free engine (PLAN.md §4). M0 ships only the module boundary;
// ByteSource arrives in M1, PieceTable and sessions in M3.

/// Build-time facts about the engine, shared by the app and tests.
public enum FilerCore {
    /// Largest file the engine is tested against (§1). Offsets are 64-bit, so this is a
    /// tested target, not a hard cap.
    public static let testedFileSizeLimit: UInt64 = 4 << 30
}
