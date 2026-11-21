import Testing

@testable import FilerCore

@Test func testedSizeIsFourGiB() {
    #expect(FilerCore.testedFileSizeLimit == 4_294_967_296)
}
