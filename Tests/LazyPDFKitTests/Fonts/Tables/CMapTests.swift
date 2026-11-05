import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Fonts/Tables/CMapTests.cs: the same cases. NextCode takes an array slice
// and gives a tuple. test_randomBytesNeverThrow draws from its own generator, so its bytes differ from the
// C# run; the shape is the same. Swift strings cannot hold a lone surrogate; test_loneSurrogateHalvesReadAsReplacementCharacters pins that difference and has no C# twin.

final class CMapTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] {
        Array(s.utf8)
    }

    private func readLength(_ map: CMap, _ b: [UInt8]) -> Int {
        map.nextCode(b[...]).length
    }

    private let header = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Test def /CMapType 2 def\n"

    func test_readsBfCharAndBfRange() {
        let map = CMap.parse(bytes(header + """
            1 begincodespacerange <00> <FF> endcodespacerange
            2 beginbfchar <01> <0041> <02> <00660069> endbfchar
            2 beginbfrange <10> <12> <0061> <20> <21> [<0058> <005900590059>] endbfrange
            endcmap
            """))
        XCTAssertEqual(map.name, "Test")
        XCTAssertEqual(map.unicodeOf(1), "A")
        XCTAssertEqual(map.unicodeOf(2), "fi")
        XCTAssertEqual(map.unicodeOf(0x10), "a")
        XCTAssertEqual(map.unicodeOf(0x12), "c")
        XCTAssertEqual(map.unicodeOf(0x20), "X")
        XCTAssertEqual(map.unicodeOf(0x21), "YYY")
        XCTAssertNil(map.unicodeOf(0x13))
        XCTAssertNil(map.unicodeOf(0x22))
    }

    func test_surrogatePairsAndTwoByteCodes() {
        let map = CMap.parse(bytes(header + """
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            1 beginbfchar <0003> <D83DDE00> endbfchar
            1 beginbfrange <0100> <0102> <D83DDE00> endbfrange
            """))
        XCTAssertEqual(map.unicodeOf(3), "\u{1F600}")
        XCTAssertEqual(map.unicodeOf(0x101), "\u{1F601}")
        let next = map.nextCode([0x01, 0x02, 0x03][...])
        XCTAssertEqual(next.code, 0x0102)
        XCTAssertEqual(next.length, 2)
    }

    func test_bfCharMayNameAGlyph() {
        let map = CMap.parse(bytes(header + "1 beginbfchar <05> /fi endbfchar"))
        XCTAssertEqual(map.unicodeOf(5), "\u{FB01}")
    }

    func test_toleratesCommentsStringsAndOddSpacing() {
        let map = CMap.parse(bytes("%!PS-Adobe\n/CIDSystemInfo << /Registry (Ado)be) /Ordering (UCS) >> def\n"
            + "1 begincodespacerange<00><FF>endcodespacerange 1 beginbfchar % c\n<41>\n<00 42>endbfchar"))
        XCTAssertEqual(map.unicodeOf(0x41), "B")
    }

    func test_readsCidMappingsAndNotdef() {
        let map = CMap.parse(bytes(header + """
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            1 beginnotdefrange <0000> <001F> 1 endnotdefrange
            2 begincidrange <0020> <007E> 100 <8000> <80FF> 500 endcidrange
            1 begincidchar <0100> 7 endcidchar
            """))
        XCTAssertEqual(map.cidOf(0x20), 100)
        XCTAssertEqual(map.cidOf(0x41), 100 + 0x41 - 0x20)
        XCTAssertEqual(map.cidOf(0x80FF), 500 + 0xFF)
        XCTAssertEqual(map.cidOf(0x100), 7)
        XCTAssertEqual(map.cidOf(0x05), 1)
        XCTAssertNil(map.cidOf(0x200))
    }

    func test_mixedLengthCodespaces() {
        let map = CMap.parse(bytes(header + """
            4 begincodespacerange <00> <80> <8140> <9FFC> <A0> <DF> <E040> <FCFC> endcodespacerange
            """))
        let s: [UInt8] = [0x41, 0x82, 0xA0, 0xB1, 0xE0, 0x40]
        var pos = 0
        var codes: [Int] = []
        var lengths: [Int] = []
        while pos < s.count {
            let next = map.nextCode(s[pos...])
            codes.append(next.code)
            lengths.append(next.length)
            pos += next.length
        }
        XCTAssertEqual(codes, [0x41, 0x82A0, 0xB1, 0xE040])
        XCTAssertEqual(lengths, [1, 2, 1, 2])
    }

    func test_invalidBytesStayInStep() {
        let map = CMap.parse(bytes(header + "2 begincodespacerange <00> <80> <8140> <9FFC> endcodespacerange"))
        var next = map.nextCode([0x81, 0x20, 0x41][...])
        XCTAssertEqual(next.code, 0x8120)
        XCTAssertEqual(next.length, 2)
        next = map.nextCode([0xFF, 0x41][...])
        XCTAssertEqual(next.code, 0xFF)
        XCTAssertEqual(next.length, 1)
        XCTAssertEqual(map.nextCode([0x81][...]).length, 1)
        XCTAssertEqual(map.nextCode([][...]).length, 0)
    }

    func test_withoutACodespaceTheMappingLengthsDecide() {
        let map = CMap.parse(bytes(header + "1 beginbfchar <0041> <0041> endbfchar"))
        let next = map.nextCode([0x00, 0x41, 0x00][...])
        XCTAssertEqual(next.code, 0x0041)
        XCTAssertEqual(next.length, 2)
    }

    func test_codesOfDifferentLengthsAreDifferentCodes() {
        let map = CMap.parse(bytes(header + """
            2 begincodespacerange <00> <7F> <8000> <FFFF> endcodespacerange
            1 begincidchar <41> 1 endcidchar
            1 begincidchar <0041> 2 endcidchar
            """))
        XCTAssertEqual(map.cidOf(0x41, length: 1), 1)
        XCTAssertEqual(map.cidOf(0x41, length: 2), 2)
        XCTAssertEqual(map.cidOf(0x41), 1)
    }

    func test_laterMappingsWinOverEarlierOnes() {
        let map = CMap.parse(bytes(header + "2 begincidrange <00> <FF> 0 <10> <1F> 900 endcidrange"))
        XCTAssertEqual(map.cidOf(0x15), 905)
        XCTAssertEqual(map.cidOf(0x30), 0x30)
    }

    func test_useCMapTakesTheParentsMappingsAndCodespace() {
        let map = CMap.parse(bytes(header + "/90ms-RKSJ-H usecmap 1 begincidchar <82A0> 9999 endcidchar"))
        XCTAssertEqual(map.cidOf(0x82A0), 9999)
        XCTAssertEqual(map.cidOf(0x41), 231 + 0x41 - 0x20)
        XCTAssertEqual(readLength(map, [0x82, 0xA0]), 2)
    }

    func test_useCMapFromTheStreamDictionary() {
        let parent = CMap.parse(bytes(header + "1 begincodespacerange <00> <FF> endcodespacerange 1 begincidchar <41> 5 endcidchar"))
        let child = CMap.parse(bytes(header + "1 begincidchar <42> 6 endcidchar"), useCMap: parent)
        XCTAssertEqual(child.cidOf(0x41), 5)
        XCTAssertEqual(child.cidOf(0x42), 6)
    }

    func test_unknownUseCMapIsIgnored() {
        let map = CMap.parse(bytes(header + "/No-Such-CMap usecmap 1 begincidchar <0041> 5 endcidchar"))
        XCTAssertEqual(map.cidOf(0x41), 5)
        XCTAssertNil(map.cidOf(0x42))
    }

    func test_readsWritingMode() {
        XCTAssertTrue(CMap.parse(bytes(header + "/WMode 1 def")).isVertical)
        XCTAssertFalse(CMap.parse(bytes(header + "/WMode 0 def")).isVertical)
    }

    func test_identityMaps() {
        let h = CMap.predefined("Identity-H")
        XCTAssertFalse(h.isVertical)
        XCTAssertTrue(CMap.predefined("Identity-V").isVertical)
        let next = h.nextCode([0x12, 0x34, 0x56][...])
        XCTAssertEqual(next.code, 0x1234)
        XCTAssertEqual(next.length, 2)
        XCTAssertEqual(h.cidOf(0x1234), 0x1234)
        XCTAssertEqual(h.cidOf(0), 0)
        XCTAssertNil(h.cidOf(0x10000))
        XCTAssertNil(h.unicodeOf(0x41))
        XCTAssertFalse(h.isFallback)
    }

    func test_shiftJisPredefined() {
        let map = CMap.predefined("90ms-RKSJ-H")
        XCTAssertEqual(map.cidOf(0x82A0), 843)
        XCTAssertEqual(readLength(map, [0x82, 0xA0]), 2)
        XCTAssertEqual(readLength(map, [0x41, 0x82, 0xA0]), 1)
        XCTAssertTrue(map === CMap.predefined("90ms-RKSJ-H"))
        XCTAssertTrue(CMap.predefined("90ms-RKSJ-V").isVertical)
    }

    func test_unicodePredefinedCMapsMapCodesToCidsAndText() {
        let map = CMap.predefined("UniJIS-UCS2-H")
        XCTAssertEqual(map.cidOf(0x3042), 843)
        XCTAssertEqual(map.unicodeOf(0x3042), "\u{3042}")
        let v = CMap.predefined("UniJIS-UTF16-V")
        XCTAssertTrue(v.isVertical)
        XCTAssertEqual(v.cidOf(0x3042), CMap.predefined("UniJIS-UTF16-H").cidOf(0x3042))
        XCTAssertEqual(CMap.predefined("UniJIS-UTF16-H").unicodeOf(Int(Int32(bitPattern: 0xD842DF9F))), "\u{20B9F}")
    }

    func test_cjkPredefinedCMapsLoad() {
        let names = [
            "GBK-EUC-H", "UniGB-UCS2-H", "B5pc-H", "ETen-B5-V", "UniCNS-UTF16-H", "KSC-EUC-H", "KSCms-UHC-H",
            "UniKS-UCS2-V", "EUC-H", "H", "V",
        ]
        for name in names {
            let map = CMap.predefined(name)
            XCTAssertFalse(map.isFallback, name)
            XCTAssertEqual(map.name, name)
            XCTAssertTrue((1...2).contains(map.nextCode([0x41, 0x42][...]).length), name)
        }
    }

    func test_unknownPredefinedNameIsTwoByteCodes() {
        let map = CMap.predefined("Adobe-Japan1-UCS2")
        XCTAssertTrue(map.isFallback)
        let next = map.nextCode([0x30, 0x42][...])
        XCTAssertEqual(next.code, 0x3042)
        XCTAssertEqual(next.length, 2)
        XCTAssertEqual(map.cidOf(0x3042), 0x3042)
    }

    func test_garbageGivesAnEmptyMap() {
        let junk = [
            "", "\0\0\0", "<<<<>>>>", "((((", "begincidrange <", "1 begincidrange <00> endcidrange",
            "begincodespacerange <0000000000> <FF> endcodespacerange", "beginbfrange <00> <10> [ <41>",
        ]
        for text in junk {
            let map = CMap.parse(bytes(text))
            XCTAssertNil(map.cidOf(0x41), text)
            XCTAssertNil(map.unicodeOf(0x41), text)
            XCTAssertTrue((1...3).contains(map.nextCode([1, 2, 3][...]).length), text)
        }
    }

    func test_reversedAndOversizedRangesAreSkipped() {
        let map = CMap.parse(bytes(header + """
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            1 begincidrange <0010> <0001> 5 endcidrange
            1 beginbfrange <0000> <FFFF> <0000> endbfrange
            """))
        XCTAssertNil(map.cidOf(5))
        XCTAssertEqual(map.unicodeOf(0x41), "A")
        XCTAssertEqual(map.unicodeOf(0xFFFF), "\u{FFFF}")
    }

    func test_randomBytesNeverThrow() {
        var state: UInt64 = 7
        func draw(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(limit))
        }
        let words = [
            "begincidrange", "endcidrange", "beginbfrange", "beginbfchar", "begincodespacerange", "/usecmap", "usecmap", "[", "]",
            "<", ">", "<41>", "<0041> <0043> 12", "(", "%", "/WMode", "99999999999999999999", "-5",
        ]
        for _ in 0..<300 {
            var data: [UInt8] = []
            for _ in 0..<200 {
                if draw(3) == 0 {
                    data.append(UInt8(draw(256)))
                } else {
                    data.append(contentsOf: words[draw(words.count)].utf8)
                }
                data.append(0x20)
            }
            let map = CMap.parse(data)
            let length = map.nextCode([0x41, 0x42, 0x43, 0x44, 0x45][...]).length
            XCTAssertTrue((1...4).contains(length))
            _ = map.cidOf(0x41)
            _ = map.unicodeOf(0x41)
        }
    }

    func test_hostileInputIsBounded() {
        var text = header + "1 begincodespacerange <00> <FF> endcodespacerange\n"
        text += String(repeating: "1 beginbfrange <00> <FF> <0041> endbfrange\n", count: 200_000)
        text += "1 beginbfchar <00> <" + String(repeating: "A", count: 2_000_000) + "> endbfchar\n"
        text += String(repeating: "<", count: 100_000) + String(repeating: "(", count: 100_000)
        let data = bytes(text)
        let start = Date()
        let map = CMap.parse(data)
        let elapsed = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsed, 5000, "\(elapsed) ms")
        XCTAssertEqual(map.unicodeOf(0x00), String(repeating: "\u{AAAA}", count: 128))
    }

    func test_manyEntriesAreCapped() {
        var text = "1 begincodespacerange <0000> <FFFF> endcodespacerange 1 begincidchar\n"
        for i in 0..<1_200_000 {
            let hex = String(i & 0xFFFF, radix: 16, uppercase: true)
            text += "<" + String(repeating: "0", count: 4 - hex.count) + hex + "> \(i)\n"
        }
        text += "endcidchar"
        let map = CMap.parse(bytes(text))
        XCTAssertNotNil(map.cidOf(0x10))
        XCTAssertEqual(map.cids.count, 1_000_000)
    }

    private func repeated(_ section: String, _ line: String, _ count: Int, _ end: String) -> String {
        "1 begincodespacerange <00000000> <FFFFFFFF> endcodespacerange\n" + section + "\n" +
            String(repeating: line + "\n", count: count) + end
    }

    func test_everyKindOfEntryStopsAtTheCap() {
        let chars = CMap.parse(bytes(repeated("begincidchar", "<00000001> 5", 1_200_000, "endcidchar")))
        XCTAssertEqual(chars.cids.count, 1_000_000)
        let ranges = CMap.parse(bytes(repeated("begincidrange", "<00000001> <00000002> 5", 1_200_000, "endcidrange")))
        XCTAssertEqual(ranges.cids.count, 1_000_000)
        let bfChars = CMap.parse(bytes(repeated("beginbfchar", "<00000001> <0041>", 1_200_000, "endbfchar")))
        XCTAssertEqual(bfChars.texts.count, 1_000_000)
        let bfRanges = CMap.parse(bytes(repeated("beginbfrange", "<00000001> <00000002> <0041>", 1_200_000, "endbfrange")))
        XCTAssertEqual(bfRanges.texts.count, 1_000_000)
        let bfArray = CMap.parse(bytes(repeated("beginbfrange\n<00000000> <FFFFFFFF> [", "<0041>", 1_200_000, "] endbfrange")))
        XCTAssertEqual(bfArray.texts.count, 1_000_000)
    }

    func test_theCapCountsNotdefsAndCidsTogether() {
        let text = repeated("beginnotdefchar", "<00000001> 5", 600_000, "endnotdefchar") + "\n1 begincidchar\n" +
            String(repeating: "<00000002> 7\n", count: 600_000) + "endcidchar"
        let map = CMap.parse(bytes(text))
        XCTAssertEqual(map.notdefs.count, 600_000)
        XCTAssertEqual(map.cids.count, 400_000)
    }

    func test_codespacesAreCappedAt100() {
        var text = ""
        for _ in 0..<2 {
            text += "60 begincodespacerange\n" + String(repeating: "<00> <FF>\n", count: 60) + "endcodespacerange\n"
        }
        XCTAssertEqual(CMap.parse(bytes(text)).spaceList.count, 100)
    }

    func test_fourByteCodesWrapWhereTheyOverflow() {
        let ranges = CMap.parse(bytes("1 begincidrange <00000000> <7FFFFFFF> 2147483647 endcidrange"))
        XCTAssertEqual(ranges.cidOf(1, length: 4), Int(Int32.min))
        XCTAssertEqual(ranges.cidOf(0, length: 4), Int(Int32.max))

        let high = CMap.parse(bytes("1 begincodespacerange <00000000> <FFFFFFFF> endcodespacerange 2 beginbfchar <80000000> <0041> <FFFFFFFF> <0042> endbfchar"))
        let first = high.nextCode([0x80, 0x00, 0x00, 0x00][...])
        XCTAssertEqual(first.code, Int(Int32.min))
        XCTAssertEqual(first.length, 4)
        XCTAssertEqual(high.unicodeOf(Int(Int32.min), length: 4), "A")
        XCTAssertEqual(high.nextCode([0xFF, 0xFF, 0xFF, 0xFF][...]).code, -1)
        XCTAssertEqual(high.unicodeOf(-1, length: 4), "B")
    }

    func test_aBfRangeArrayPastTheLastCodeWraps() {
        let map = CMap.parse(bytes("1 beginbfrange <FFFFFFFE> <FFFFFFFF> [<0041> <0042> <0043>] endbfrange"))
        XCTAssertEqual(map.unicodeOf(-2, length: 4), "A")
        XCTAssertEqual(map.unicodeOf(-1, length: 4), "B")
        XCTAssertEqual(map.unicodeOf(0, length: 4), "C")
    }

    // Not in the C#: a Swift String cannot hold a lone surrogate, so each half reads as U+FFFD.
    func test_loneSurrogateHalvesReadAsReplacementCharacters() {
        let map = CMap.parse(bytes("1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <01> <D83D> <02> <DE00> endbfchar"))
        XCTAssertEqual(map.unicodeOf(1), "\u{FFFD}")
        XCTAssertEqual(map.unicodeOf(2), "\u{FFFD}")
    }

    func test_unknownNamesGiveAFallbackThatIsNotKept() {
        let first = CMap.predefined("No-Such-CMap-H")
        XCTAssertTrue(first.isFallback)
        XCTAssertFalse(first === CMap.predefined("No-Such-CMap-H"))
        XCTAssertTrue(CMap.predefined("Identity-H") === CMap.predefined("Identity-H"))
    }
}
