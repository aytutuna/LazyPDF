import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Syntax/PdfBytesTests.cs: the same cases. The stream is a file here,
// where C# has a MemoryStream.

final class PdfBytesTests: XCTestCase {
    private func sample(_ length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        var state: UInt32 = 12345
        for i in 0..<length {
            state = state &* 1664525 &+ 1013904223
            bytes[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return bytes
    }

    private func stream(_ data: [UInt8]) throws -> PdfStreamBytes {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(data).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try PdfStreamBytes(file: try FileHandle(forReadingFrom: url))
    }

    func test_arrayBytesPastTheEndReadAsMinusOne() {
        let bytes = PdfArrayBytes([7, 8, 9])
        XCTAssertEqual(bytes.length, 3)
        XCTAssertEqual(bytes[1], 8)
        XCTAssertEqual(bytes[3], -1)
        XCTAssertEqual(bytes[-1], -1)
        XCTAssertEqual(bytes[Int.max], -1)
        XCTAssertEqual(bytes.read(1, 10), [8, 9])
        XCTAssertEqual(bytes.read(3, 1), [])
        XCTAssertEqual(bytes.read(-1, 1), [])
        XCTAssertEqual(bytes.read(0, 0), [])
        XCTAssertEqual(bytes.read(0, -4), [])
        XCTAssertEqual(bytes.read(0, 1), [7])
    }

    func test_streamBytesReadAcrossBlocksLikeTheArray() throws {
        let data = sample(300_000)
        let array = PdfArrayBytes(data)
        let stream = try stream(data)
        XCTAssertEqual(array.length, stream.length)
        for at in [0, 1, 65535, 65536, 65537, 131071, 299_999, 300_000, -1] {
            XCTAssertEqual(array[at], stream[at], "\(at)")
        }
        for (at, count) in [(0, 10), (65530, 20), (65536, 65536), (1000, 250_000), (299_990, 100), (400_000, 5)] {
            XCTAssertEqual(array.read(at, count), stream.read(at, count), "\(at), \(count)")
        }
        // More blocks than the cache keeps, then back to the first.
        for at in stride(from: 0, to: data.count, by: 70_000) {
            XCTAssertEqual(array[at], stream[at])
        }
        XCTAssertEqual(array[5], stream[5])
    }

    func test_lexerReadsFromAStreamAsFromAnArray() throws {
        let data = Latin1.bytes("%x\n<</A [1 2 (three)] /B 4 0 R>> stream\nabc")
        let fromArray = try XCTUnwrap(try PdfLexer(PdfArrayBytes(data)).readObject() as? PdfStream)
        let fromStream = try XCTUnwrap(try PdfLexer(try stream(data)).readObject() as? PdfStream)
        XCTAssertEqual(fromArray.dictionary.description, fromStream.dictionary.description)
        XCTAssertEqual(fromArray.dataOffset, fromStream.dataOffset)
    }

    func test_nonFiniteNumbersWriteZero() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(PdfNumber(value).text, "0")
        }
    }

    func test_lexerFarOutsideTheBytesReadsTheEnd() {
        for position in [Int.max, Int.max - 1, Int.min, -5, 3, 1000] {
            let lexer = PdfLexer(PdfArrayBytes(Latin1.bytes("abc")), position: position)
            XCTAssertEqual(lexer.readKeyword(), "", "\(position)")
            XCTAssertNil(lexer.tryReadUnsigned(), "\(position)")
            XCTAssertThrowsError(try lexer.readObject(), "\(position)")
            XCTAssertThrowsError(try lexer.readObjectHeader(), "\(position)")
        }
    }

    func test_nameAboveLatin1IsWrittenAsItsUtf8Bytes() throws {
        XCTAssertEqual(PdfName("Ş").description, "/#C5#9E")
        XCTAssertEqual(PdfName.fromText("Ş").description, "/#C5#9E")
        let read = try XCTUnwrap(try PdfLexer(PdfArrayBytes(Latin1.bytes("/#C5#9E"))).readObject() as? PdfName)
        XCTAssertEqual(read.text, "Ş")
        let latin = try XCTUnwrap(try PdfLexer(PdfArrayBytes(Latin1.bytes("/#FC"))).readObject() as? PdfName)
        XCTAssertEqual(latin.text, latin.value)
    }

    func test_nameMixingLatin1AndAboveIsWrittenAsUtf8Throughout() throws {
        let name = PdfName("GÖZDEN GEÇİRİLDİ")
        XCTAssertFalse(name.description.contains("#D6"))
        let read = try XCTUnwrap(try PdfLexer(PdfArrayBytes(Latin1.bytes(name.description))).readObject() as? PdfName)
        XCTAssertEqual(read.text, "GÖZDEN GEÇİRİLDİ")
    }
}
