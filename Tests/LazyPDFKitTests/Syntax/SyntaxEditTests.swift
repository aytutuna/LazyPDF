import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/SyntaxEditTests.cs: the same cases.

final class SyntaxEditTests: XCTestCase {
    func test_largeDictionaryLooksKeysUpThroughTheIndex() {
        let dictionary = PdfDictionary()
        for i in 0..<2000 { dictionary.add("K\(i)", PdfNumber(i)) }
        XCTAssertEqual((dictionary["K1234"] as? PdfNumber)?.integer, 1234)
        dictionary["K1234"] = PdfNumber(-1)
        XCTAssertEqual((dictionary["K1234"] as? PdfNumber)?.integer, -1)
        dictionary.add("K5", PdfNumber(55))
        XCTAssertEqual((dictionary["K5"] as? PdfNumber)?.integer, 55)
        XCTAssertTrue(dictionary.remove("K5"))
        XCTAssertNil(dictionary["K5"])
        XCTAssertFalse(dictionary.containsKey("K5"))
        XCTAssertEqual(dictionary.count, 1999)
        dictionary["New"] = PdfNull.instance
        XCTAssertTrue(dictionary.containsKey("New"))
        dictionary["New"] = nil
        XCTAssertFalse(dictionary.containsKey("New"))
    }

    func test_writingAHugeDictionaryIsLinear() {
        let dictionary = PdfDictionary()
        for i in 0..<200_000 { dictionary.add("K\(i)", PdfNumber(i)) }
        let start = Date()
        let text = dictionary.description
        XCTAssertTrue(text.hasPrefix("<</K0 0 /K1 1"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func test_repeatedKeysWriteOnceWithTheLastValue() {
        let dictionary = PdfDictionary()
        dictionary.add("A", PdfNumber(1))
        dictionary.add("B", PdfNumber(2))
        dictionary.add("A", PdfNumber(3))
        XCTAssertEqual(dictionary.description, "<</B 2 /A 3>>")
        XCTAssertEqual(PdfDictionary().description, "<<>>")
    }

    func test_aRealIsWrittenWithoutAnExponent() {
        XCTAssertEqual(PdfNumber(0.5).text, "0.5")
        XCTAssertEqual(PdfNumber(1.0).text, "1")
        XCTAssertEqual(PdfNumber(-0.0000001).text, "0")
        XCTAssertEqual(PdfNumber(123456789.0).text, "123456789")
        XCTAssertEqual(PdfNumber(-7.0 / 3).text, "-2.333333")
        XCTAssertEqual(PdfNumber(7).text, "7")
    }

    func test_stringBytesCanBeReplaced() {
        let text = PdfString(bytes: Latin1.bytes("ab"), isHex: false)
        text.bytes = [0x41]
        XCTAssertEqual(text.description, "(A)")
    }

    func test_aNumberKeepsItsTextAndReadsItsValue() {
        for (text, value) in [("4.", 4.0), ("-.5", -0.5), ("+.5", 0.5), ("0012", 12.0), ("1.25", 1.25)] {
            XCTAssertEqual(PdfNumber(text).value, value, text)
        }
        XCTAssertNil(PdfNumber("4.").integer)
        XCTAssertEqual(PdfNumber("0012").integer, 12)
        XCTAssertEqual(PdfNumber("+3").integer, 3)
        XCTAssertNil(PdfNumber("9223372036854775808").integer)
    }

    func test_rectangleWritesAsAnArray() {
        XCTAssertEqual(PdfRect(612, 792, 0, 0).toArray().description, "[0 0 612 792]")
        XCTAssertEqual(PdfRect(0, 0, 10, 10).intersect(PdfRect(-5, -5, 5, 5)), PdfRect(0, 0, 5, 5))
        XCTAssertTrue(PdfRect(0, 0, 1, 1).intersect(PdfRect(5, 5, 6, 6)).isEmpty)
    }

    func test_aNameFromTextIsWrittenAsEscapedUtf8AndReadsBack() throws {
        let name = PdfName.fromText("\u{15E} \u{130}")
        XCTAssertEqual(name.description, "/#C5#9E#20#C4#B0")
        let read = try XCTUnwrap(try PdfLexer(PdfArrayBytes(Latin1.bytes(name.description))).readObject() as? PdfName)
        XCTAssertEqual(read.text, "\u{15E} \u{130}")
        XCTAssertEqual(name, read)
    }

    func test_aLatin1NameIsWrittenAsBefore() {
        XCTAssertEqual(PdfName("Caf\u{E9}").description, "/Caf#E9")
        XCTAssertEqual(PdfName("Caf\u{E9}").text, "Caf\u{E9}")
    }

    func test_aNameWithCharsAboveLatin1IsNeverTruncated() {
        XCTAssertEqual(PdfName("\u{15E}").description, "/#C5#9E")
        XCTAssertEqual(PdfName("A\u{E9}\u{15E}").description, "/A#C3#A9#C5#9E")
    }
}
