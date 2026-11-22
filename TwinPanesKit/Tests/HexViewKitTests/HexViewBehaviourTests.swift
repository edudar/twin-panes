import AppKit
import Testing

@testable import HexViewKit

/// A data source whose cache, prefetch results and short reads the test controls.
@MainActor
final class FakeHexSource: HexViewDataSource {
    let data: Data
    /// Whether `cachedBytes` answers; prefetch success turns it on.
    var cached = false
    /// Returned by every prefetch; nil means success (which also fills the cache).
    var prefetchError: Error?
    /// Bytes cut off every `cachedBytes` answer, to imitate a file that got shorter.
    var shortBy = 0
    private(set) var prefetches: [Range<UInt64>] = []

    init(count: Int) { data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }) }

    var length: UInt64 { UInt64(data.count) }

    func cachedBytes(_ range: Range<UInt64>) -> Data? {
        guard cached else { return nil }
        let end = max(Int(range.lowerBound), Int(range.upperBound) - shortBy)
        return data[Int(range.lowerBound)..<end]
    }

    func prefetch(_ range: Range<UInt64>, completion: @escaping @MainActor (Error?) -> Void) {
        prefetches.append(range)
        if prefetchError == nil { cached = true }
        completion(prefetchError)
    }

    func read(_ range: Range<UInt64>) throws -> Data {
        data[Int(range.lowerBound)..<Int(range.upperBound)]
    }
}

@MainActor
final class DelegateSpy: HexViewDelegate {
    var errors = 0
    func hexViewSelectionDidChange(_ view: HexView) {}
    func hexView(_ view: HexView, selectionTooLargeToCopy range: Range<UInt64>) {}
    func hexView(_ view: HexView, didFailToRead error: Error) { errors += 1 }
}

struct ReadFailed: Error {}

/// HexView behaviour against a fake source, drawn offscreen (no window needed).
@MainActor
@Suite struct HexViewBehaviourTests {
    let source: FakeHexSource
    let spy = DelegateSpy()
    let view = HexView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))

    init() {
        source = FakeHexSource(count: 100_000)
        view.options.bytesPerRow = .fixed(16)
        view.delegate = spy
        view.dataSource = source
    }

    func render(times: Int = 1) {
        for _ in 0..<times {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
        }
    }

    /// Since macOS 14 views don't clip by default; an unclipped hex view painted over
    /// the tab bar above it (bug, 2026-11-21).
    @Test func clipsToItsBounds() {
        #expect(view.clipsToBounds)
    }

    @Test func asksForTheVisibleRowsOnceWhenUncached() {
        render(times: 3)
        #expect(source.prefetches.count == 1)
        let visible = view.layout.rowStart(view.position.visibleRows.lowerBound)
        #expect(source.prefetches.first?.contains(visible) == true)
    }

    /// Review bug 2: a read that keeps failing was requested again on every redraw.
    @Test func doesNotRetryAFailedRangeUntilItScrolls() {
        source.prefetchError = ReadFailed()
        render(times: 10)
        #expect(source.prefetches.count == 1)
        #expect(spy.errors == 1)
        view.go(to: 90_000)
        render(times: 10)
        #expect(source.prefetches.count == 2)
        #expect(spy.errors == 2)
    }

    /// Review bug 1: bytes shorter than asked for (a file truncated after open) drew past
    /// the end of the data and trapped.
    @Test func drawsShortDataAsPlaceholders() {
        source.cached = true
        source.shortBy = 40
        render()
        view.go(to: 50_000)
        render()
    }
}
