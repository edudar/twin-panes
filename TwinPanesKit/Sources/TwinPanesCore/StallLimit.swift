import Foundation

/// A main-thread stall limit scaled to the machine it runs on (docs/plans/M4.md,
/// performance pass): the same work stalls a slower Mac for longer. The limit is the
/// one set on the reference machine (the dev Mac), times how much slower this machine
/// runs a fixed reference workload: never below it, and at most `maxFactor` times it,
/// past which a machine is too slow for the limit to say anything.
public struct StallLimit: Sendable, Equatable {
    /// The limit on the reference machine.
    public let base: Duration
    /// How much slower this machine is, from 1 to the cap.
    public let factor: Double

    public init(base: Duration, measured: Duration, reference: Duration, maxFactor: Double = 4) {
        self.init(base: base, measured: [measured], reference: [reference], maxFactor: maxFactor)
    }

    /// Several workloads, each timed here and on the reference machine: the machine is as
    /// slow as its slowest kind of work.
    public init(
        base: Duration, measured: [Duration], reference: [Duration], maxFactor: Double = 4
    ) {
        self.base = base
        let ratios = zip(measured, reference).map { $1 > .zero ? $0 / $1 : 1 }
        factor = min(maxFactor, max(1, ratios.max() ?? 1))
    }

    public var limit: Duration { base * factor }

    /// The fastest of `runs` runs of `body`: what the machine can do, not how busy it
    /// happened to be during one of them.
    public static func fastest(of runs: Int, _ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return (0..<max(1, runs)).map { _ in clock.measure(body) }.min() ?? .zero
    }
}
