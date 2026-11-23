import Foundation
import Testing

@testable import TwinPanesCore

/// The smoke test's stall limit, scaled to the machine (docs/plans/M4.md, performance
/// pass).
@Suite struct StallLimitTests {
    let base = Duration.milliseconds(50)
    let reference = Duration.milliseconds(40)

    @Test func aFasterMachineKeepsTheReferenceLimit() {
        let limit = StallLimit(base: base, measured: .milliseconds(20), reference: reference)
        #expect(limit.factor == 1 && limit.limit == base)
    }

    @Test func aSlowerMachineGetsAProportionallyLongerLimit() {
        let limit = StallLimit(base: base, measured: .milliseconds(100), reference: reference)
        #expect(limit.factor == 2.5)
        #expect(limit.limit == .milliseconds(125))
    }

    @Test func theFactorIsCapped() {
        let limit = StallLimit(
            base: base, measured: .seconds(4), reference: reference, maxFactor: 3)
        #expect(limit.factor == 3 && limit.limit == .milliseconds(150))
    }

    @Test func noReferenceMeansNoScaling() {
        #expect(StallLimit(base: base, measured: .seconds(1), reference: .zero).factor == 1)
    }

    /// A run slowed by something else doesn't count against the machine.
    @Test func theFastestRunIsTheMeasure() {
        var run = 0
        let fastest = StallLimit.fastest(of: 3) {
            run += 1
            Thread.sleep(forTimeInterval: run == 2 ? 0.001 : 0.05)
        }
        #expect(run == 3)
        #expect(fastest < .milliseconds(25))
    }
}
