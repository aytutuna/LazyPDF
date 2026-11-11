import XCTest
@testable import LazyPDFKit

final class FilterBufferTests: XCTestCase {
    func test_fillsUpToTheCapAndRefusesTheNextByte() throws {
        let buffer = FilterBuffer(1000)
        for i in 0..<1000 { try buffer.add(UInt8(i & 0xFF)) }
        XCTAssertEqual(buffer.count, 1000)
        XCTAssertThrowsError(try buffer.add(1)) { error in
            XCTAssertEqual((error as? PdfReadException)?.message, "A stream expands past the size limit.")
        }
        XCTAssertEqual(buffer.count, 1000)
    }

    func test_runsThatCrossTheCapAreRefusedWhole() throws {
        let buffer = FilterBuffer(1000)
        try buffer.add([UInt8](repeating: 0, count: 600))
        XCTAssertThrowsError(try buffer.add([UInt8](repeating: 0, count: 401)))
        XCTAssertEqual(buffer.count, 600)
        try buffer.add([UInt8](repeating: 0, count: 400))
        XCTAssertEqual(buffer.count, 1000)
        XCTAssertEqual(buffer.toArray().count, 1000)
    }
}
