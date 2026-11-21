import Testing

@testable import TwinPanesCore

@Test func testedSizeIsFourGiB() {
    #expect(TwinPanesCore.testedFileSizeLimit == 4_294_967_296)
}
