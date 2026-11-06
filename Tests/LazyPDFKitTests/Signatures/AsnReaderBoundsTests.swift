import XCTest
@testable import LazyPDFKit

// No C# twin: System.Formats.Asn1 refuses a short-form length that runs past the data, and so must AsnReader, since a
// certificate in a file's /DSS can be any bytes (SignatureOverlapTests reads "0 g" as one).

final class AsnReaderBoundsTests: XCTestCase {
    func test_aShortFormLengthPastTheEndOfTheDataIsRefused() {
        var reader = AsnReader([0x30, 0x20, 0x67])

        XCTAssertThrowsError(try reader.readEncodedValue())
        XCTAssertThrowsError(try reader.peekEncodedValue())
    }

    func test_aShortFormLengthThatFitsIsRead() throws {
        var reader = AsnReader([0x30, 0x01, 0x67])

        XCTAssertEqual(try reader.readEncodedValue(), [0x30, 0x01, 0x67])
    }
}
