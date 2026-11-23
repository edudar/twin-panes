import Foundation

/// Main-actor work timed by name, so the smoke test can say what filled a stall
/// (docs/plans/M4.md, performance pass, step 1). Off unless a recorder is set: then
/// `measure` costs one nil check.
@MainActor
public enum StepTiming {
    public static var recorder: StepRecorder?

    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let step = start(name)
        defer { step?.end() }
        return try body()
    }

    /// For a whole function: `let step = StepTiming.start("show"); defer { step?.end() }`.
    static func start(_ name: String) -> Running? {
        recorder.map { Running(recorder: $0, name: name, start: .now, cpuStart: threadCPU()) }
    }

    @MainActor struct Running {
        let recorder: StepRecorder
        let name: String
        let start: ContinuousClock.Instant
        let cpuStart: Duration

        func end() {
            recorder.record(name, from: start, to: .now, onCPU: threadCPU() - cpuStart)
        }
    }

    /// This thread's time on the CPU so far: a step whose wall time is much longer
    /// waited for a core, a lock or the disk rather than worked.
    static func threadCPU() -> Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }
}

/// The timed steps since `reset()`.
@MainActor
public final class StepRecorder {
    /// One name's steps that overlapped a span of time.
    public struct Step: Equatable, Sendable {
        public let name: String
        public let count: Int
        /// The time of these steps inside the span.
        public let total: Duration
        public let longest: Duration
        /// The CPU time of all these steps (each one whole), and of the longest.
        public let onCPU: Duration
        public let longestOnCPU: Duration
    }

    private typealias Record = (
        name: String, start: ContinuousClock.Instant, end: ContinuousClock.Instant,
        onCPU: Duration
    )
    private var records: [Record] = []
    /// Enough for a gate's worth of cell draws; older records are dropped past this.
    let limit: Int

    public init(limit: Int = 200_000) { self.limit = limit }

    public func reset() { records.removeAll(keepingCapacity: true) }

    func record(
        _ name: String, from start: ContinuousClock.Instant, to end: ContinuousClock.Instant,
        onCPU: Duration = .zero
    ) {
        if records.count >= limit { records.removeFirst(records.count / 2) }
        records.append((name, start, end, onCPU))
    }

    /// The steps that overlapped `start..<end`, the most time first. Nested steps
    /// (a refresh inside a show) each count their own time.
    public func steps(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
    )
        -> [Step]
    {
        var byName: [String: (Int, Duration, Duration, Duration, Duration)] = [:]
        for record in records where record.end > start && record.start < end {
            let inside = min(record.end, end) - max(record.start, start)
            var (count, total, longest, onCPU, longestOnCPU) =
                byName[record.name] ?? (0, .zero, .zero, .zero, .zero)
            count += 1
            total += inside
            onCPU += record.onCPU
            if record.end - record.start > longest {
                (longest, longestOnCPU) = (record.end - record.start, record.onCPU)
            }
            byName[record.name] = (count, total, longest, onCPU, longestOnCPU)
        }
        return byName.map {
            Step(
                name: $0.key, count: $0.value.0, total: $0.value.1, longest: $0.value.2,
                onCPU: $0.value.3, longestOnCPU: $0.value.4)
        }
        .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }
}
