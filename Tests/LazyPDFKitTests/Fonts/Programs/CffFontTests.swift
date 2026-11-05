import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Programs/CffFontTests.cs: the same cases. The damage test uses its own
// generator where the C# has System.Random.

final class CffFontTests: XCTestCase {
    private func segments(_ o: GlyphOutline?) -> [OutlineSegment] {
        o?.segments ?? []
    }

    private func parse(_ data: [UInt8]) throws -> CffFont {
        try XCTUnwrap(CffFont.tryParse(data))
    }

    func test_cidFontMatrixComesFromTheFontDictsAndMultipliesWithTheTop() throws {
        XCTAssertEqual(try parse(CffBuilder.cidKeyed()).fontMatrix[0], 0.001)
        XCTAssertEqual(try parse(CffBuilder.cidKeyed(nil, [2, 0, 0, 2, 0, 0])).fontMatrix, [2.0, 0, 0, 2.0, 0, 0])
        XCTAssertEqual(try parse(CffBuilder.cidKeyed([3, 0, 0, 3, 0, 0], [2, 0, 0, 2, 0, 0])).fontMatrix, [6.0, 0, 0, 6.0, 0, 0])
    }

    func test_nameKeyedFontReadsNamesAndEncoding() throws {
        let f = try parse(CffBuilder.nameKeyed())

        XCTAssertEqual(f.name, "Test")
        XCTAssertFalse(f.isCid)
        XCTAssertEqual(f.glyphCount, 4)
        XCTAssertEqual(f.glyphName(1), "A")
        XCTAssertEqual(f.glyphName(2), "B")
        XCTAssertEqual(f.glyphName(3), "custom")
        XCTAssertEqual(f.glyphName(0), ".notdef")
        XCTAssertEqual(f.glyphForName("custom"), 3)
        XCTAssertEqual(f.glyphForName("nothing"), 0)
        XCTAssertEqual(f.glyphForCode(0x41), 1)
        XCTAssertEqual(f.glyphForCode(0x42), 2)
        XCTAssertEqual(f.glyphForCode(0x43), 0)
        XCTAssertEqual(f.fontBounds, GlyphBounds(0, 0, 200, 200))
        XCTAssertEqual(f.fontMatrix[0], 0.001)
    }

    func test_widthIsNominalPlusDeltaOrTheDefault() throws {
        let f = try parse(CffBuilder.nameKeyed())

        XCTAssertEqual(f.getWidth(1), 600)
        XCTAssertEqual(f.getWidth(2), 300)
        XCTAssertEqual(f.getWidth(3), 300)
        XCTAssertEqual(f.getWidth(0), 300)
        XCTAssertEqual(f.getWidth(4), 0)
        XCTAssertEqual(f.getWidth(-1), 0)
    }

    func test_linesCurvesAndSubroutinesBecomeAnOutline() throws {
        let f = try parse(CffBuilder.nameKeyed())

        XCTAssertEqual(segments(f.getOutline(1)), [
            OutlineSegment(.move, 50, 0), OutlineSegment(.line, 150, 0), OutlineSegment(.line, 150, 100), OutlineSegment(.line, 50, 100),
            OutlineSegment(.close, 0, 0),
        ])

        XCTAssertEqual(segments(f.getOutline(2)), [
            OutlineSegment(.move, 10, 20), OutlineSegment(.cubic, 70, 50, 40, 20, 40, 50), OutlineSegment(.close, 0, 0),
        ])
    }

    func test_hintMaskBytesAreSkipped() throws {
        let f = try parse(CffBuilder.nameKeyed())

        XCTAssertEqual(segments(f.getOutline(3)), [
            OutlineSegment(.move, 100, 100), OutlineSegment(.line, 110, 100), OutlineSegment(.line, 110, 120), OutlineSegment(.close, 0, 0),
        ])
    }

    func test_cidKeyedFontUsesPerGlyphPrivateDicts() throws {
        let f = try parse(CffBuilder.cidKeyed())

        XCTAssertTrue(f.isCid)
        XCTAssertEqual(f.glyphCount, 4)
        XCTAssertNil(f.glyphName(1))
        XCTAssertEqual(f.glyphForCid(10), 1)
        XCTAssertEqual(f.glyphForCid(11), 2)
        XCTAssertEqual(f.glyphForCid(500), 3)
        XCTAssertEqual(f.glyphForCid(12), 0)
        XCTAssertEqual(f.cidForGlyph(3), 500)
        XCTAssertEqual(f.getWidth(1), 600)
        XCTAssertEqual(f.getWidth(2), 350)
        XCTAssertEqual(f.getWidth(3), 350)
        XCTAssertEqual(f.getWidth(0), 250)
        XCTAssertEqual(segments(f.getOutline(2))[1].op, .cubic)
    }

    func test_nameKeyedFontUsesCidAsGlyphIndex() throws {
        let f = try parse(CffBuilder.nameKeyed())

        XCTAssertEqual(f.glyphForCid(2), 2)
        XCTAssertEqual(f.glyphForCid(40), 0)
    }

    func test_truncatedFontIsRefusedOrReadsSafely() {
        for cut in [0, 3, 10, 40, 100] {
            let data = CffBuilder.nameKeyed()
            guard let f = CffFont.tryParse(Array(data[..<cut])) else { continue }
            for g in 0..<f.glyphCount {
                _ = f.getOutline(g)
                _ = f.getWidth(g)
            }
        }
    }

    func test_damagedFontsNeverThrow() {
        var rng = ProgramFonts.Random(3)
        for source in [CffBuilder.nameKeyed(), CffBuilder.cidKeyed()] {
            for round in 0..<3000 {
                var data = source
                for _ in 0..<(1 + round % 6) { data[rng.next(data.count)] = UInt8(rng.next(256)) }
                guard let f = CffFont.tryParse(data) else { continue }
                for g in 0..<min(f.glyphCount, 50) {
                    _ = f.getOutline(g)
                    _ = f.getWidth(g)
                    _ = f.glyphName(g)
                }
                _ = f.glyphForName("A")
                _ = f.glyphForCid(10)
            }
        }
    }

    func test_runawaySubroutineRecursionStops() throws {
        // Local subr 0 calls itself, once and twice: depth and operator limits end both.
        for subr in [CffBuilder.code(-107, "callsubr", "return"), CffBuilder.code(-107, "callsubr", -107, "callsubr", "return")] {
            let f = try parse(CffBuilder.nameKeyed(subr))
            XCTAssertNotNil(f.getOutline(2))
            XCTAssertEqual(f.getWidth(2), 300)
        }
    }

    func test_arithmeticAndStackOperators() throws {
        let cases: [([CodePart], Double, Double)] = [
            ([10, 20, "add", "dup", "rlineto"], 40, 50),
            ([20, 4, "div", 5, 3, "mul", "rlineto"], 15, 35),
            ([1, 2, "exch", "rlineto"], 12, 21),
            ([9, 8, 7, "drop", "rlineto"], 19, 28),
            ([10, 3, "sub", 0, "rlineto"], 17, 20),
        ]
        for (code, x, y) in cases {
            let subr = CffBuilder.code(code + ["return"])
            let f = try parse(CffBuilder.nameKeyed(subr))

            let outline = segments(f.getOutline(2))
            XCTAssertEqual(outline[1], OutlineSegment(.line, x, y), "\(x) \(y)")
        }
    }

    func test_interOpenTypeMatchesItsMetrics() throws {
        guard let data = ProgramFonts.otf() else { return }
        let sfnt = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let cff = try XCTUnwrap(sfnt.cff)

        XCTAssertEqual(sfnt.glyphCount, cff.glyphCount)
        XCTAssertEqual(sfnt.unitsPerEm, Int((1 / cff.fontMatrix[0]).rounded(.toNearestOrEven)))
        var checkedGlyphs = 0
        var g = 0
        while g < cff.glyphCount {
            XCTAssertEqual(Double(sfnt.getAdvance(g)), cff.getWidth(g))
            let outline = try XCTUnwrap(cff.getOutline(g))
            if !outline.isEmpty {
                let box = try XCTUnwrap(outline.bounds())
                XCTAssertTrue(box.xMin >= sfnt.fontBounds.xMin - 1 && box.xMax <= sfnt.fontBounds.xMax + 1)
                XCTAssertTrue(box.yMin >= sfnt.fontBounds.yMin - 1 && box.yMax <= sfnt.fontBounds.yMax + 1)
            }
            checkedGlyphs += 1
            g += 11
        }
        XCTAssertTrue(checkedGlyphs > 50)
    }

    func test_interNamesAndOutlines() throws {
        guard let data = ProgramFonts.otf() else { return }
        let sfnt = try XCTUnwrap(TrueTypeFont.tryParse(data))
        let cff = try XCTUnwrap(sfnt.cff)

        let a = sfnt.glyphForCodePoint(0x41)
        XCTAssertEqual(cff.glyphName(a), "uni0041")
        XCTAssertEqual(cff.glyphForName("uni0041"), a)
        XCTAssertEqual(sfnt.glyphName(a), "uni0041")
        let outline = try XCTUnwrap(cff.getOutline(a))
        XCTAssertEqual(outline.segments.filter { $0.op == .move }.count, outline.segments.filter { $0.op == .close }.count)
        XCTAssertNotEqual(sfnt.glyphForCodePoint(0x011F), 0)
        XCTAssertNotEqual(sfnt.glyphForCodePoint(0x0131), 0)
    }

    func test_bareCffTableParsesLikeTheOpenTypeFont() throws {
        guard let data = ProgramFonts.otf() else { return }
        let at = ProgramFonts.tableOffset(data, "CFF ")
        let e = ProgramFonts.directoryEntry(data, "CFF ")
        let length = (Int(data[e + 12]) << 24) | (Int(data[e + 13]) << 16) | (Int(data[e + 14]) << 8) | Int(data[e + 15])

        let bare = try XCTUnwrap(CffFont.tryParse(data, at, length))
        let viaSfnt = try XCTUnwrap(try XCTUnwrap(TrueTypeFont.tryParse(data)).cff)
        XCTAssertEqual(viaSfnt.glyphCount, bare.glyphCount)
        XCTAssertEqual(viaSfnt.getWidth(5), bare.getWidth(5))
    }

    func test_notCffGivesNull() {
        XCTAssertNil(CffFont.tryParse([]))
        XCTAssertNil(CffFont.tryParse([UInt8](repeating: 0, count: 64)))
        XCTAssertNil(CffFont.tryParse(Array("hello world, not a font".utf8)))
        XCTAssertNil(CffFont.tryParse([UInt8](repeating: 0, count: 10), 8, 10))
    }
}
