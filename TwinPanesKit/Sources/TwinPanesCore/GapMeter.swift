import Foundation

/// Gaps between a thread's heartbeats, and how much of each the thread spent working
/// (docs/plans/M4.md, performance pass). A gap where the thread was busy is a stall it
/// caused. A gap where it barely ran is the thread waiting for a core, which on a
/// shared CI machine depends on everything else running there.
public struct GapMeter: Sendable {
    /// The longest gap, and when it ended.
    public private(set) var worstWall = Duration.zero
    public private(set) var worstWallEnd: ContinuousClock.Instant?
    /// The most CPU time the thread used inside one gap, when that gap ended, and how
    /// long it lasted.
    public private(set) var worstBusy = Duration.zero
    public private(set) var worstBusyEnd: ContinuousClock.Instant?
    public private(set) var worstBusyWall = Duration.zero
    private var last: (wall: ContinuousClock.Instant, cpu: Duration)?

    public init() {}

    /// A heartbeat at `wall`, when the thread had used `cpu` in all.
    public mutating func beat(at wall: ContinuousClock.Instant, cpu: Duration) {
        guard let last else {
            self.last = (wall, cpu)
            return
        }
        let gap = wall - last.wall
        if gap > worstWall { (worstWall, worstWallEnd) = (gap, wall) }
        guard cpu > .zero, cpu >= last.cpu else {
            self.last = (wall, last.cpu)
            return
        }
        let busy = cpu - last.cpu
        if busy > worstBusy { (worstBusy, worstBusyEnd, worstBusyWall) = (busy, wall, gap) }
        self.last = (wall, cpu)
    }

    /// The calling thread's CPU time so far.
    public static func threadCPU() -> Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }
}
