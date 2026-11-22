import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct InspectorTests {
    func values(_ bytes: [UInt8], _ endianness: Inspector.Endianness = .little) -> [String: String]
    {
        var out: [String: String] = [:]
        for row in Inspector.rows(for: Data(bytes), endianness: endianness) {
            out[row.name] = row.value ?? "—"
        }
        return out
    }

    @Test func decodesIntegersInBothByteOrders() {
        let bytes: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
        let little = values(bytes)
        #expect(little["Int8"] == "-2")
        #expect(little["UInt8"] == "254")
        #expect(little["Int16"] == "-2")
        #expect(little["UInt16"] == "65534")
        #expect(little["Int32"] == "-2")
        #expect(little["UInt64"] == "9223372036854775806")
        let big = values(bytes, .big)
        #expect(big["UInt16"] == "65279")
        #expect(big["Int64"] == "-72057594037928065")
        #expect(big["Binary"] == "1111 1110")
    }

    @Test func decodesFloats() {
        #expect(values([0x00, 0x3C])["Float16"] == "1.0")
        #expect(values([0x00, 0x00, 0x80, 0x3F])["Float32"] == "1.0")
        #expect(
            values([0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18], .big)["Float64"]
                == "3.141592653589793")
        #expect(values([0x00, 0x00, 0x80, 0x7F])["Float32"] == "inf")
        #expect(values([0x00, 0x00, 0xC0, 0x7F])["Float32"] == "nan")
    }

    @Test func rowsNeedingMoreBytesAreEmpty() {
        let rows = values([0x41])
        #expect(rows["UInt8"] == "65")
        #expect(rows["UInt16"] == "—")
        #expect(rows["Float64"] == "—")
        #expect(rows["UTF-8"] == "U+0041 “A”")
        #expect(rows["UTF-16"] == "—")
        #expect(Inspector.rows(for: Data(), endianness: .little).allSatisfy { $0.value == nil })
    }

    @Test func decodesCharacters() {
        #expect(values([0xC3, 0xA9])["UTF-8"] == "U+00E9 “é”")
        #expect(values([0xE2, 0x82, 0xAC])["UTF-8"] == "U+20AC “€”")
        #expect(values([0xF0, 0x9F, 0x98, 0x80])["UTF-8"] == "U+1F600 “😀”")
        #expect(values([0x80])["UTF-8"] == "invalid")
        #expect(values([0xC3])["UTF-8"] == "invalid")
        #expect(values([0x0A])["UTF-8"] == "U+000A")
        #expect(values([0x3D, 0xD8, 0x00, 0xDE])["UTF-16"] == "U+1F600 “😀”")
        #expect(values([0x00, 0xE9], .big)["UTF-16"] == "U+00E9 “é”")
        #expect(values([0x00, 0xDC])["UTF-16"] == "invalid")
    }

    @Test func decodesTimestamps() {
        // 2001-01-01T00:00:00Z in each format.
        let unix = UInt32(978_307_200)
        #expect(
            values(withUnsafeBytes(of: unix.littleEndian, Array.init))["Unix time (32-bit)"]
                == "2001-01-01T00:00:00Z")
        let preEpoch = Int32(-86_400)
        #expect(
            values(withUnsafeBytes(of: preEpoch.littleEndian, Array.init))["Unix time (32-bit)"]
                == "1969-12-31T00:00:00Z")
        let mac = Double(0).bitPattern
        #expect(
            values(withUnsafeBytes(of: mac.littleEndian, Array.init))["Mac absolute time"]
                == "2001-01-01T00:00:00Z")
        let filetime = UInt64(126_227_808_000_000_000)
        #expect(
            values(withUnsafeBytes(of: filetime.littleEndian, Array.init))["Windows FILETIME"]
                == "2001-01-01T00:00:00Z")
        #expect(values(Array(repeating: 0x7F, count: 8))["Mac absolute time"] == "out of range")
        #expect(
            values(withUnsafeBytes(of: Double.nan.bitPattern.littleEndian, Array.init))[
                "Mac absolute time"] == "out of range")
        #expect(
            values(withUnsafeBytes(of: UInt64.max.littleEndian, Array.init))["Windows FILETIME"]
                == "out of range")
    }
}
