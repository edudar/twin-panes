import AppKit
import Testing
import TwinPanesCore

@testable import BrowserKit

@MainActor
@Suite struct QuickLookHostViewTests {
    final class FakeQuickLookViewer: QuickLookViewing {
        let view = NSView()
        var shown: [URL?] = []
        var closeCount = 0

        func show(_ url: URL?) { shown.append(url) }
        func close() { closeCount += 1 }
    }

    private final class ScopeProbe {
        weak var scope: SecurityScope?
    }

    private func show(_ url: URL?, in host: QuickLookHostView) -> ScopeProbe {
        let probe = ScopeProbe()
        do {
            let scope = SecurityScope(url: url ?? URL(fileURLWithPath: "/tmp"))
            probe.scope = scope
            host.show(url, scope: scope)
        }
        return probe
    }

    @Test func retainsScopeUntilRetargetedOrClearedAndEmbedsView() {
        let fake = FakeQuickLookViewer()
        let host = QuickLookHostView(viewer: fake)
        #expect(fake.view.superview === host)
        let urlA = URL(fileURLWithPath: "/tmp/a.txt")
        let urlB = URL(fileURLWithPath: "/tmp/b.txt")

        let probeA = show(urlA, in: host)
        #expect(probeA.scope != nil)
        #expect(fake.shown == [urlA])

        let probeB = show(urlB, in: host)
        #expect(probeA.scope == nil)
        #expect(probeB.scope != nil)
        #expect(fake.shown == [urlA, urlB])

        let cleared = show(nil, in: host)
        #expect(probeB.scope == nil)
        #expect(cleared.scope == nil)
        #expect(fake.shown == [urlA, urlB, nil])
    }

    @Test func closeIsIdempotentClearsScopeAndIgnoresSubsequentShows() {
        let fake = FakeQuickLookViewer()
        let host = QuickLookHostView(viewer: fake)
        let url = URL(fileURLWithPath: "/tmp/a.txt")

        let probe = show(url, in: host)
        #expect(probe.scope != nil)

        host.close()
        host.close()
        #expect(fake.closeCount == 1)
        #expect(probe.scope == nil)

        let afterClose = show(url, in: host)
        #expect(afterClose.scope == nil)
        #expect(fake.shown == [url])
    }
}
