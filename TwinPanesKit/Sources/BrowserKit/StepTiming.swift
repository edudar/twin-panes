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
        recorder.map { Running(recorder: $0, name: name, start: .now) }
    }

    @MainActor struct Running {
        let recorder: StepRecorder
        let name: String
        let start: ContinuousClock.Instant

        func end() { recorder.record(name, from: start, to: .now) }
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
    }

    private var records:
        [(name: String, start: ContinuousClock.Instant, end: ContinuousClock.Instant)] =
            []
    /// Enough for a gate's worth of cell draws; older records are dropped past this.
    let limit: Int

    public init(limit: Int = 200_000) { self.limit = limit }

    public func reset() { records.removeAll(keepingCapacity: true) }

    func record(
        _ name: String, from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
    ) {
        if records.count >= limit { records.removeFirst(records.count / 2) }
        records.append((name, start, end))
    }

    /// The steps that overlapped `start..<end`, the most time first. Nested steps
    /// (a refresh inside a show) each count their own time.
    public func steps(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
    )
        -> [Step]
    {
        var byName: [String: (count: Int, total: Duration, longest: Duration)] = [:]
        for record in records where record.end > start && record.start < end {
            let inside = min(record.end, end) - max(record.start, start)
            var step = byName[record.name] ?? (0, .zero, .zero)
            step.count += 1
            step.total += inside
            step.longest = max(step.longest, record.end - record.start)
            byName[record.name] = step
        }
        return byName.map {
            Step(name: $0.key, count: $0.value.0, total: $0.value.1, longest: $0.value.2)
        }
        .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }
}
