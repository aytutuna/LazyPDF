import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/Jbig2ArithTests.cs.
final class Jbig2ArithTests: XCTestCase {
    // The test sequence of T.88 H.2: 256 decisions under one context, and what the MQ encoder makes of them.
    private let decisions = Hex.bytes("00020051000000C00352872AAAAAAAAA82C02000FCD79EF6BF7FED904F46A3BF")
    private let coded = Hex.bytes("84C73BFCE1A1430402200000410DBB86F4317FFF88FF37471ADB6ADFFFAC")

    private func bit(_ i: Int) -> Int { Int(decisions[i / 8] >> UInt8(7 - i % 8)) & 1 }

    func test_encoderMakesTheStandardsCodedBytes() {
        let e = ArithEncoder()
        let context = Jbig2Contexts(1)
        for i in 0..<256 { e.bit(context, 0, bit(i)) }
        XCTAssertEqual(e.finish(), coded)
    }

    func test_decoderReadsTheStandardsCodedBytes() throws {
        let arith = try Jbig2Arith(coded, 0, coded.count)
        let context = Jbig2Contexts(1)
        for i in 0..<256 { XCTAssertEqual(arith.bit(context, 0), bit(i), "decision \(i)") }
    }
}
