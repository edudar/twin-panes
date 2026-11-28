import Foundation
import Testing

@testable import TwinPanesCore

@MainActor
@Suite struct PreviewFormatOverridesTests {
    private func makeIsolatedDefaults() throws -> (UserDefaults, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PreviewFormatOverrides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = try #require(
            UserDefaults(suiteName: dir.appendingPathComponent("prefs.plist").path))
        return (defaults, dir)
    }

    @Test func overrideRawValueAndCodableRoundTrip() throws {
        let all =
            StructuredFormat.allCases.map(PreviewFormatOverride.structured)
            + [.plainText, .preview, .hex]
        let (encoder, decoder) = (JSONEncoder(), JSONDecoder())
        for value in all {
            #expect(PreviewFormatOverride(rawValue: value.rawValue) == value)
            #expect(
                try decoder.decode(PreviewFormatOverride.self, from: encoder.encode(value)) == value
            )
        }
        #expect(PreviewFormatOverride(rawValue: "unknown") == nil)
        #expect(PreviewFormatOverride(rawValue: "") == nil)
    }

    @Test func persistsNormalizesAndIgnoresInvalidValues() throws {
        let (defaults, dir) = try makeIsolatedDefaults()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PreviewFormatOverrides(defaults: defaults)
        #expect(store.override(forExtension: "geojson") == nil)
        store.set(.structured(.json), forExtension: ".GEOJSON")
        store.set(.plainText, forExtension: "xcconfig")
        store.set(.preview, forExtension: "custom")
        store.set(.hex, forExtension: "dat")
        store.set(.plainText, forExtension: "")
        store.set(.plainText, forExtension: "...")

        let reloaded = PreviewFormatOverrides(defaults: defaults)
        #expect(reloaded.override(forExtension: "geojson") == .structured(.json))
        #expect(reloaded.override(forExtension: "..GeoJSON") == .structured(.json))
        #expect(reloaded.override(forExtension: "xcconfig") == .plainText)
        #expect(reloaded.override(forExtension: "custom") == .preview)
        #expect(reloaded.override(forExtension: "dat") == .hex)
        #expect(reloaded.override(forExtension: "") == nil)

        reloaded.remove(forExtension: ".GEOJSON")
        #expect(PreviewFormatOverrides(defaults: defaults).override(forExtension: "geojson") == nil)

        defaults.set(
            ["bad": "notAFormat", "ok": "toml"], forKey: "PreviewFormatOverrides.byExtension")
        let withCorrupt = PreviewFormatOverrides(defaults: defaults)
        #expect(withCorrupt.override(forExtension: "bad") == nil)
        #expect(withCorrupt.override(forExtension: "ok") == .structured(.toml))
    }
}
