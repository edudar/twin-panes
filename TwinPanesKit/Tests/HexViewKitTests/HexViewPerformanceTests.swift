import AppKit
import XCTest

@testable import HexViewKit

/// A throttled data source imitating a slow network/USB volume (PLAN.md §7): prefetches
/// never finish synchronously, so drawing must render placeholders immediately without
/// blocking.
@MainActor
private final class ThrottledHexSource: HexViewDataSource {
    let length: UInt64 = 4 << 30
    func cachedBytes(_ range: Range<UInt64>) -> Data? { nil }
    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void) {}
    func read(_ range: Range<UInt64>) throws -> Data { Data(count: Int(range.count)) }
}

@MainActor
private final class CachedHexSource: HexViewDataSource {
    let data = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
    var length: UInt64 { 4 << 30 }
    func cachedBytes(_ range: Range<UInt64>) -> Data? {
        let count = Int(range.count)
        guard count <= data.count else { return nil }
        return data.prefix(count)
    }
    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void) {
        completion(nil)
    }
    func read(_ range: Range<UInt64>) throws -> Data {
        data.prefix(Int(range.count))
    }
}

/// XCTest `measure`-based frame-time tests (D22, PLAN.md §7): cached Core Text redraws
/// and uncached placeholder redraws over a throttled source on a 4 GiB view.
@MainActor
final class HexViewPerformanceTests: XCTestCase {
    func testCachedFrameDrawPerformance() {
        let source = CachedHexSource()
        let view = HexView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
        view.options.bytesPerRow = .fixed(16)
        view.dataSource = source
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("could not create bitmap backing")
        }
        measure {
            for step in 0..<10 {
                view.go(to: UInt64(step) * (source.length / 10))
                view.cacheDisplay(in: view.bounds, to: rep)
            }
        }
    }

    func testThrottledPlaceholderDrawPerformance() {
        let source = ThrottledHexSource()
        let view = HexView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
        view.options.bytesPerRow = .fixed(16)
        view.dataSource = source
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("could not create bitmap backing")
        }
        measure {
            for step in 0..<10 {
                view.go(to: UInt64(step) * (source.length / 10))
                view.cacheDisplay(in: view.bounds, to: rep)
            }
        }
    }
}
