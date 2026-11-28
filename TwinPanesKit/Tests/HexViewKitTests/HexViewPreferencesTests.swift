import Foundation
import Testing

@testable import HexViewKit

@MainActor
@Suite struct HexViewPreferencesTests {
    private func makeIsolatedDefaults() throws -> (UserDefaults, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HexViewPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = try #require(
            UserDefaults(suiteName: dir.appendingPathComponent("prefs.plist").path))
        return (defaults, dir)
    }

    @Test func persistsAndRestoresAllFourOptions() throws {
        let (defaults, dir) = try makeIsolatedDefaults()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HexViewPreferences(defaults: defaults)
        #expect(store.options == HexViewOptions())

        let updated = HexViewOptions(
            bytesPerRow: .fixed(32), grouping: 4, offsetBase: .both, textEncoding: .latin1)
        store.options = updated
        let reloaded = HexViewPreferences(defaults: defaults)
        #expect(reloaded.options == updated)

        reloaded.options.bytesPerRow = .autoFit
        #expect(HexViewPreferences(defaults: defaults).options.bytesPerRow == .autoFit)
    }

    @Test func invalidStoredValuesFallBackToDefaults() throws {
        let (defaults, dir) = try makeIsolatedDefaults()
        defer { try? FileManager.default.removeItem(at: dir) }

        defaults.set(12, forKey: "hexView.bytesPerRow")
        defaults.set(3, forKey: "hexView.grouping")
        defaults.set("octal", forKey: "hexView.offsetBase")
        defaults.set("ebcdic", forKey: "hexView.textEncoding")
        #expect(HexViewPreferences(defaults: defaults).options == HexViewOptions())
    }

    @Test func notifiesLiveObserversOnChangeAndDropsDeadOwners() {
        let store = HexViewPreferences()
        var received: [HexViewOptions] = []
        final class Token {}
        var token: Token? = Token()
        store.observe(token!) { received.append($0) }

        store.options = HexViewOptions()
        #expect(received.isEmpty)
        let changed = HexViewOptions(bytesPerRow: .fixed(8), grouping: 2)
        store.options = changed
        #expect(received == [changed])
        token = nil
        store.options = HexViewOptions(offsetBase: .decimal)
        #expect(received.count == 1)
    }
}
