import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportZipTests.cs: the same cases. The packages are read by `ExportZipReader`,
// which stands in for ZipArchive; the noise is what System.Random gives for seed 4.

final class ExportZipTests: XCTestCase {
    func test_theCheckValueOfTheStandardTestString() {
        XCTAssertEqual(ExportZip.crc32(Array("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(ExportZip.crc32(Array("6789".utf8), ExportZip.crc32(Array("12345".utf8))), 0xCBF43926)
        XCTAssertEqual(ExportZip.crc32([]), 0)
    }

    func test_textIsDeflatedAndAlreadyPackedDataIsStored() throws {
        let text = Array(String(repeating: "lazy pdf ", count: 500).utf8)
        let noise = FilterFixtures.randomBytes(2000, 4)
        let package = try ExportZip.make([ExportZipEntry("a.txt", text), ExportZipEntry("b.bin", noise), ExportZipEntry("c.txt", [])])

        let files = try ExportZipReader.read(package)
        XCTAssertEqual(files.map { $0.name }, ["a.txt", "b.bin", "c.txt"])
        XCTAssertLessThan(files[0].compressedSize, text.count / 4)
        XCTAssertEqual(files[1].compressedSize, 2000)
        // 1980-01-01 at midnight, whatever the machine's clock says.
        for f in files { XCTAssertEqual(f.dosDate, 33, f.name) }
        XCTAssertEqual(files[0].data, text)
        XCTAssertEqual(files[1].data, noise)
        XCTAssertEqual(files[0].crc, ExportZip.crc32(text))
    }

    func test_namesOutsideAsciiAreFlaggedAsUtf8() throws {
        let package = try ExportZip.make([ExportZipEntry("ğüş/İ.txt", [1, 2, 3])])
        let files = try ExportZipReader.read(package)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].name, "ğüş/İ.txt")
        XCTAssertEqual(files[0].flags & 0x0800, 0x0800)
    }

    func test_theSameEntriesGiveTheSameBytes() throws {
        let entries = [ExportZipEntry("x.xml", Array("<a/>".utf8))]
        XCTAssertEqual(try ExportZip.make(entries), try ExportZip.make(entries))
    }
}
