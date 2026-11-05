import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/Type1FontTests.cs: the same cases. The damage test uses its
// own generator where the C# has System.Random.

final class Type1FontTests: XCTestCase {
    private let variants: [(Type1Wrapper, Int, Bool)] = [
        (.binary, 4, false),
        (.hex, 4, false),
        (.pfb, 4, false),
        (.binary, 4, true),
        (.binary, 0, false),
        (.hex, -1, true),
    ]

    private func font(_ w: Type1Wrapper = .binary, _ lenIV: Int = 4, _ bar: Bool = false) throws -> Type1Font {
        try XCTUnwrap(Type1Font.tryParse(Type1Builder.build(w, lenIV, bar)))
    }

    private func segments(_ o: GlyphOutline?) -> [OutlineSegment] {
        o?.segments ?? []
    }

    func test_headerAndGlyphsAreRead() throws {
        for (wrapper, lenIV, bar) in variants {
            let f = try font(wrapper, lenIV, bar)
            let label = "\(wrapper) \(lenIV) \(bar)"

            XCTAssertEqual(f.fontName, "TestFont", label)
            XCTAssertEqual(f.glyphNames, Type1Builder.glyphNames, label)
            XCTAssertEqual(f.fontBounds, GlyphBounds(-10, -20, 900, 800), label)
            XCTAssertEqual(f.fontMatrix[0], 0.001, label)
            XCTAssertEqual(f.builtInEncoding[65], "A", label)
            XCTAssertEqual(f.builtInEncoding[66], "B", label)
            XCTAssertEqual(f.builtInEncoding[67], "C", label)
            XCTAssertNil(f.builtInEncoding[0], label)
            XCTAssertNil(f.builtInEncoding[200], label)
            XCTAssertTrue(f.hasGlyph("G"), label)
            XCTAssertFalse(f.hasGlyph("Z"), label)
        }
    }

    func test_widthsComeFromHsbwAndSbw() throws {
        for (wrapper, lenIV, bar) in variants {
            let f = try font(wrapper, lenIV, bar)
            let label = "\(wrapper) \(lenIV) \(bar)"

            XCTAssertEqual(f.getWidth(".notdef"), 250, label)
            XCTAssertEqual(f.getWidth("A"), 600, label)
            XCTAssertEqual(f.getWidth("B"), 500, label)
            XCTAssertEqual(f.getWidth("C"), 700, label)
            XCTAssertEqual(f.getWidth("F"), 300, label)
            XCTAssertEqual(f.getWidth("missing"), 0, label)
        }
    }

    func test_linesStartAtTheSideBearing() throws {
        XCTAssertEqual(segments(try font().getOutline("A")), [
            OutlineSegment(.move, 50, 0), OutlineSegment(.line, 150, 0), OutlineSegment(.line, 150, 100), OutlineSegment(.line, 50, 100),
            OutlineSegment(.close, 0, 0),
        ])
    }

    func test_flexBecomesTwoCurves() throws {
        for (wrapper, lenIV, bar) in variants {
            XCTAssertEqual(segments(try font(wrapper, lenIV, bar).getOutline("B")), [
                OutlineSegment(.move, 10, 10),
                OutlineSegment(.cubic, 50, 15, 30, 10, 40, 15),
                OutlineSegment(.cubic, 80, 10, 60, 15, 70, 10),
                OutlineSegment(.line, 80, 110),
                OutlineSegment(.close, 0, 0),
            ], "\(wrapper) \(lenIV) \(bar)")
        }
    }

    func test_seacComposesBaseAndAccent() throws {
        let f = try font()
        let a = segments(f.getOutline("A"))
        let b = segments(f.getOutline("B"))

        // asb 20, adx 30, ady 40 and sbx 0 put the accent at (10, 40).
        let moved = b.map { s -> OutlineSegment in
            if s.op == .close { return s }
            var t = s
            t.x += 10
            t.y += 40
            t.x1 += 10
            t.y1 += 40
            t.x2 += 10
            t.y2 += 40
            return t
        }
        XCTAssertEqual(segments(f.getOutline("C")), a + moved)
    }

    func test_divHintReplacementAndCurves() throws {
        let f = try font()

        XCTAssertEqual(segments(f.getOutline("D")), [OutlineSegment(.move, 0, 0), OutlineSegment(.line, 50, 0), OutlineSegment(.close, 0, 0)])
        XCTAssertEqual(segments(f.getOutline("E")), [OutlineSegment(.move, 0, 0), OutlineSegment(.line, 10, 0), OutlineSegment(.close, 0, 0)])
        XCTAssertEqual(segments(f.getOutline("F")), [OutlineSegment(.move, 10, 20), OutlineSegment(.line, 10, 25), OutlineSegment(.close, 0, 0)])
        XCTAssertEqual(segments(f.getOutline("G")), [
            OutlineSegment(.move, 0, 0),
            OutlineSegment(.cubic, 20, 10, 10, 0, 10, 10),
            OutlineSegment(.cubic, 35, 25, 20, 15, 30, 25),
            OutlineSegment(.cubic, 42, 36, 38, 25, 42, 30),
            OutlineSegment(.close, 0, 0),
        ])
    }

    func test_missingGlyphHasNoOutline() throws {
        XCTAssertNil(try font().getOutline("Q"))
    }

    func test_standardEncodingIsExpanded() throws {
        let text = Latin1.string(Type1Builder.build(.binary))
            .replacingOccurrences(of: "/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\ndup 65 /A put\ndup 66 /B put\ndup 8#103 /C put\nreadonly def", with: "/Encoding StandardEncoding def", options: .literal)
        let f = try XCTUnwrap(Type1Font.tryParse(Latin1.bytes(text)))

        XCTAssertEqual(f.builtInEncoding[65], "A")
        XCTAssertEqual(f.builtInEncoding[174], "fi")
        XCTAssertEqual(f.builtInEncoding[251], "germandbls")
        XCTAssertNil(f.builtInEncoding[0])
    }

    func test_notAType1FontGivesNull() {
        XCTAssertNil(Type1Font.tryParse([]))
        XCTAssertNil(Type1Font.tryParse([UInt8](repeating: 0, count: 300)))
        XCTAssertNil(Type1Font.tryParse(Array("%!PS-AdobeFont-1.0\n/FontName /X def\ncurrentfile eexec\n".utf8)))
        XCTAssertNil(Type1Font.tryParse([0x80, 1, 255, 255, 255, 127, 1, 2, 3]))
    }

    func test_truncatedAndDamagedFontsNeverThrow() {
        var rng = ProgramFonts.Random(11)
        for wrapper in [Type1Wrapper.binary, .hex, .pfb] {
            let data = Type1Builder.build(wrapper)
            var cut = 0
            while cut < data.count {
                exercise(Array(data[..<cut]))
                cut += 13
            }
            for round in 0..<400 {
                var copy = data
                for _ in 0..<(1 + round % 8) { copy[rng.next(copy.count)] = UInt8(rng.next(256)) }
                exercise(copy)
            }
        }
    }

    private func exercise(_ data: [UInt8]) {
        guard let f = Type1Font.tryParse(data) else { return }
        for name in f.glyphNames {
            _ = f.getOutline(name)
            _ = f.getWidth(name)
        }
    }

    func test_charstringLengthNearTheIntegerLimitGivesNoFontNotAnException() {
        let clear = Latin1.bytes(
            "%!PS-AdobeFont-1.0: T 001\n/FontName /T def\n/FontMatrix [0.001 0 0 0.001 0 0] readonly def\n" +
            "/FontBBox {0 0 1 1} readonly def\ncurrentdict end\ncurrentfile eexec\n")
        let secret = Latin1.bytes(
            "dup /Private 8 dict dup begin\n/RD {string currentfile exch readstring pop} executeonly def\n" +
            "/CharStrings 1 dict dup begin\n/A 2147483647 RD abcdef ND\nend\nend\n")
        let trailer = Latin1.bytes(String(repeating: "0", count: 64) + "\ncleartomark\n")
        let font = clear + Type1Builder.encrypt(secret, 55665, 4) + trailer
        _ = Type1Font.tryParse(font)
    }
}
