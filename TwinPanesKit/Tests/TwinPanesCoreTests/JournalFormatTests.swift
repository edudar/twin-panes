import Foundation
import Testing

@testable import TwinPanesCore

struct JournalFormatTests {
    func randomRecords(_ rng: inout SplitMix64, count: Int) -> [JournalRecord] {
        (0..<count).map { _ in
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: return .saved(UInt64.random(in: 0...1000, using: &rng))
            case 1: return .closed
            default:
                let lower = UInt64.random(in: 0..<(1 << 40), using: &rng)
                let pieces = (0..<Int.random(in: 0...4, using: &rng)).map { _ in
                    Piece(
                        Bool.random(using: &rng) ? .original : .add,
                        offset: UInt64.random(in: 0...UInt64.max / 2, using: &rng),
                        length: UInt64.random(in: 1..<(1 << 32), using: &rng))
                }
                let length = pieces.reduce(UInt64(0)) { $0 + $1.length }
                return .replace(lower..<(lower + length), pieces)
            }
        }
    }

    @Test func crc32cMatchesTheStandardCheckValue() {
        #expect(JournalFormat.crc32c(Array("123456789".utf8)) == 0xE306_9283)
        #expect(JournalFormat.crc32c([UInt8]()) == 0)
    }

    @Test func recordsRoundTrip() {
        var rng = SplitMix64(seed: 0x10E7_0000_0000_0001)
        let records =
            [.saved(0), .closed, .replace(5..<5, [])] + randomRecords(&rng, count: 200)
        let data = records.map(JournalFormat.encode).reduce(Data(), +)
        let decoded = JournalFormat.decode(data)
        #expect(decoded.records == records && decoded.validLength == data.count)
    }

    /// A crash can cut the file anywhere; the reader returns exactly the whole records
    /// before the cut.
    @Test func everyTruncationReadsTheWholeRecordsBeforeIt() {
        var rng = SplitMix64(seed: 0x10E7_0000_0000_0002)
        let records = randomRecords(&rng, count: 12)
        let frames = records.map(JournalFormat.encode)
        let data = frames.reduce(Data(), +)
        var ends: [Int] = [0]
        for frame in frames { ends.append(ends.last! + frame.count) }
        for cut in 0...data.count {
            let whole = ends.lastIndex { $0 <= cut }!
            let decoded = JournalFormat.decode(data.prefix(cut))
            #expect(decoded.records == Array(records[..<whole]), "cut at \(cut)")
            #expect(decoded.validLength == ends[whole], "cut at \(cut)")
        }
    }

    /// A damaged byte never turns into a wrong record: everything before the damaged
    /// record still reads, nothing from it on does.
    @Test func damageStopsReadingAtTheDamagedRecord() {
        let seed: UInt64 = 0x10E7_0000_0000_0003
        var rng = SplitMix64(seed: seed)
        for round in 0..<300 {
            let records = randomRecords(&rng, count: 8)
            let frames = records.map(JournalFormat.encode)
            var data = frames.reduce(Data(), +)
            let at = Int.random(in: 0..<data.count, using: &rng)
            data[at] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            var start = 0, damaged = 0
            while start + frames[damaged].count <= at {
                start += frames[damaged].count
                damaged += 1
            }
            let decoded = JournalFormat.decode(data)
            #expect(
                decoded.records == Array(records[..<damaged]),
                "seed \(seed), round \(round), byte \(at)")
        }
    }
}
