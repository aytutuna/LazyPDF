import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/LinearizerKit.cs: the same helpers. The PigText overloads open a file in
// PdfPig and have no twin; the tests that call them compare the engine's own text (TextText) in their place. Regular
// expressions are NSRegularExpression over the Latin-1 text, where one character is one byte.

enum LinearizerKit {
    static let fileId = (1...16).map { UInt8($0) }

    /// A file of `count` pages: catalog 1 with bookmarks, a page tree 2 whose resources (4) every page inherits unless
    /// it has its own, a shared font 3 and form 6, an info 8, pages from 10, then their contents, then on odd pages a
    /// font of their own. Each page links to the next.
    static func make(_ count: Int, _ header: String = "%PDF-1.4\n") -> [UInt8] {
        let pdf = TestPdf(header)
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Outlines 5 0 R /PageMode /UseOutlines>>")
        let kids = (0..<count).map { "\(10 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 200 300] /Resources 4 0 R>>")
        pdf.obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.obj(4, "<</Font <</F1 3 0 R>> /XObject <</Fm 6 0 R>>>>")
        pdf.obj(5, "<</Type /Outlines /First 7 0 R /Last 7 0 R /Count 1>>")
        pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 0 5 5 re f")
        pdf.obj(7, "<</Title (First) /Parent 5 0 R /Dest [\(10 + count - 1) 0 R /Fit]>>")
        pdf.obj(8, "<</Title (Linearizer test)>>")
        for i in 0..<count {
            let own = i % 2 == 1 ? " /Resources <</Font <</F1 3 0 R /F2 \(10 + 2 * count + i) 0 R>> /XObject <</Fm 6 0 R>>>>" : ""
            let link = " /Annots [<</Type /Annot /Subtype /Link /Rect [0 0 20 20] /Dest [\(10 + (i + 1) % count) 0 R /Fit]>>]"
            pdf.obj(10 + i, "<</Type /Page /Parent 2 0 R /Contents \(10 + count + i) 0 R\(own)\(link)>>")
        }
        for i in 0..<count {
            pdf.stream(10 + count + i, "", "BT /F1 12 Tf 20 100 Td (Page number \(i + 1)) Tj ET q /Fm Do Q")
            if i % 2 == 1 { pdf.obj(10 + 2 * count + i, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>") }
        }
        let id = PdfGraph.hex(fileId)
        return pdf.finish("/Root 1 0 R /Info 8 0 R /ID [<\(id)> <\(id)>]")
    }

    static func secure(_ strength: PdfCryptStrength, _ user: String = "") -> PdfSecurity {
        PdfSecurity.create(userPassword: user, ownerPassword: "owner", permissions: .all, strength: strength, firstId: fileId, random: SeededRandom(3))
    }

    /// The text of every page as the engine reads it, joined by "|".
    static func textText(_ document: PdfDocument) -> String {
        let cache = TextCache(document)
        return (0..<document.pages.count).map { cache.get($0).text }.joined(separator: "|")
    }

    static func textText(_ file: [UInt8]) throws -> String { textText(try PdfDocument.open(file)) }

    /// With LAZYPDF_LINEARIZE_OUT naming a folder, the file is left there for other readers.
    @discardableResult
    static func keep(_ name: String, _ file: [UInt8]) -> [UInt8] {
        if let folder = ProcessInfo.processInfo.environment["LAZYPDF_LINEARIZE_OUT"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? Data(file).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".pdf"))
        }
        return file
    }

    private static func matches(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) throws -> [NSTextCheckingResult] {
        let expression = try NSRegularExpression(pattern: pattern, options: options)
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        (text as NSString).substring(with: match.range(at: index))
    }

    private static var counter = 0

    /// Checks everything a reader relies on in a linearized file (Annex F): the parameters, both cross-reference
    /// sections against the real object positions, and the hint tables against the pages. Returns the parameters.
    @discardableResult
    static func verify(_ file: [UInt8], _ password: String? = nil) throws -> [String: Int] {
        if password == nil {
            counter += 1
            keep(String(format: "verified-%03d", counter), file)
        }
        let text = Latin1.string(file)
        // Object starts: a number and " 0 obj" at the start of a line, by position.
        var starts: [Int: Int] = [:]
        for m in try matches("(?<=\\n)(\\d+) 0 obj\\n", text) { starts[m.range.location] = Int(group(m, 1, text)) }
        let sortedStarts = starts.keys.sorted()
        var offsetOf: [Int: Int] = [:]
        for (position, number) in starts { offsetOf[number] = position }
        let lins = try matches("/Linearized 1 /L (\\d+) /H \\[ (\\d+) (\\d+) \\] /O (\\d+) /E (\\d+) /N (\\d+) /T (\\d+)\\s*>>", text)
        let lin = try XCTUnwrap(lins.first, "linearization dictionary")
        func param(_ i: Int) -> Int { Int(group(lin, i, text)) ?? -1 }
        let parameters = ["L": param(1), "H0": param(2), "H1": param(3), "O": param(4), "E": param(5), "N": param(6), "T": param(7)]
        XCTAssertEqual(file.count, parameters["L"])
        XCTAssertTrue(lin.range.location < sortedStarts[1])
        let sections = try matches("(?<=\\n)xref\\n(\\d+) (\\d+)\\n", text)
        XCTAssertEqual(2, sections.count)
        let first = sections[0]
        let main = sections[1]
        let tail = String(text.suffix(40))
        XCTAssertTrue(try !matches("startxref\\n\(first.range.location)\\n%%EOF\\n$", tail).isEmpty, "startxref")
        let mainCount = Int(group(main, 2, text)) ?? 0
        XCTAssertEqual(parameters["T"], main.range.location + "xref\n".utf8.count + "0 \(group(main, 2, text))".utf8.count)
        let t = try XCTUnwrap(parameters["T"])
        XCTAssertEqual(10, t < file.count ? file[t] : 0)
        XCTAssertEqual(0, Int(group(main, 1, text)))
        XCTAssertEqual(mainCount, Int(group(first, 1, text)))
        let firstCount = Int(group(first, 2, text)) ?? 0
        let afterFirst = (text as NSString).substring(from: first.range.location)
        let trailers = try matches("trailer\\n<<(.*?)>>\\nstartxref\\n0\\n%%EOF\\n", afterFirst, options: [.dotMatchesLineSeparators])
        let trailer = try XCTUnwrap(trailers.first)
        let entries = group(trailer, 1, afterFirst)
        XCTAssertTrue(entries.contains("/Size \(mainCount + firstCount)"), entries)
        let prev = try XCTUnwrap(try matches("/Prev (\\d+)", entries).first)
        XCTAssertEqual(main.range.location, Int(group(prev, 1, entries)))
        XCTAssertTrue((text as NSString).substring(from: main.range.location).contains("/Size \(mainCount)"))

        func checkEntries(_ section: NSTextCheckingResult, _ firstNumber: Int, _ count: Int, _ freeFirst: Bool) throws {
            var at = section.range.location + section.range.length
            var number = firstNumber
            for i in 0..<count {
                let entry = (text as NSString).substring(with: NSRange(location: at, length: 20))
                if freeFirst && i == 0 {
                    XCTAssertEqual("0000000000 65535 f \n", entry)
                } else {
                    XCTAssertTrue(try !matches("^\\d{10} 00000 n \\n$", entry, options: [.anchorsMatchLines]).isEmpty, entry)
                    XCTAssertEqual(offsetOf[number], Int(entry.prefix(10)), "object \(number)")
                }
                at += 20
                number += 1
            }
        }
        XCTAssertEqual(starts[sortedStarts[0]], Int(group(first, 1, text)))
        try checkEntries(first, Int(group(first, 1, text)) ?? 0, firstCount, false)
        try checkEntries(main, 0, mainCount, true)

        let hintAt = try XCTUnwrap(parameters["H0"])
        XCTAssertNotNil(starts[hintAt])
        XCTAssertNotNil(starts[hintAt + (parameters["H1"] ?? 0)])
        let hintHead = (text as NSString).substring(with: NSRange(location: hintAt, length: 30))
        XCTAssertTrue(try !matches("^\\d+ 0 obj\\n<</S \\d+", hintHead).isEmpty, hintHead)
        let document = try PdfDocument.open(file, password: password)
        XCTAssertTrue(document.isLinearized)
        XCTAssertEqual(parameters["N"], document.pages.count)
        XCTAssertEqual(parameters["O"], document.pages[0].reference.number)
        try verifyHints(document, file, starts, sortedStarts, offsetOf, parameters, main.range.location)
        return parameters
    }

    private static func verifyHints(_ document: PdfDocument, _ file: [UInt8], _ starts: [Int: Int], _ sortedStarts: [Int], _ offsetOf: [Int: Int],
                                    _ lin: [String: Int], _ mainAt: Int) throws {
        func next(_ start: Int) -> Int { sortedStarts.first { $0 > start } ?? mainAt }
        func lengthOf(_ number: Int) -> Int { next(offsetOf[number] ?? 0) - (offsetOf[number] ?? 0) }
        let hintObject = try XCTUnwrap(document.get(starts[lin["H0"] ?? 0] ?? 0) as? PdfStream, "hint stream")
        let data = document.rawData(hintObject)
        let sharedAt = try XCTUnwrap(document.integer(hintObject.dictionary, "S"))
        let hintLength = lin["H1"] ?? 0
        var r = BitReader(data)
        let minObjects = r.read(32)
        let firstAt = r.read(32)
        let bitsObjects = r.read(16)
        let minLength = r.read(32)
        let bitsLength = r.read(16)
        let minOffset = r.read(32)
        let bitsOffset = r.read(16)
        let minContent = r.read(32)
        let bitsContent = r.read(16)
        let bitsCount = r.read(16)
        let bitsId = r.read(16)
        let bitsNumerator = r.read(16)
        XCTAssertEqual(0, bitsNumerator)
        _ = r.read(16)
        let pages = lin["N"] ?? 0
        func column(_ bits: Int, _ least: Int) -> [Int] {
            let values = (0..<pages).map { _ in least + r.read(bits) }
            r.align()
            return values
        }
        let objects = column(bitsObjects, minObjects)
        let lengths = column(bitsLength, minLength)
        let counts = column(bitsCount, 0)
        let ids = counts.map { c in (0..<c).map { _ in r.read(bitsId) } }
        r.align()
        let offsets = column(bitsOffset, minOffset)
        let spans = column(bitsContent, minContent)
        XCTAssertEqual(sharedAt, r.position)
        let sharedFirst = r.read(32)
        let sharedFirstAt = r.read(32)
        let sharedFirstPage = r.read(32)
        let sharedTotal = r.read(32)
        XCTAssertEqual(0, r.read(16))
        let minGroup = r.read(32)
        let bitsGroup = r.read(16)
        let groups = (0..<sharedTotal).map { _ in minGroup + r.read(bitsGroup) }
        r.align()
        for _ in 0..<sharedTotal { XCTAssertEqual(0, r.read(1)) }
        r.align()
        if let outlineAt = document.integer(hintObject.dictionary, "O") {
            XCTAssertEqual(outlineAt, r.position)
            let outlineFirst = r.read(32)
            let outlineStart = r.read(32) + hintLength
            let outlineCount = r.read(32)
            let outlineLength = r.read(32)
            XCTAssertEqual((document.catalog["Outlines"] as? PdfReference)?.number, outlineFirst)
            XCTAssertEqual(offsetOf[outlineFirst], outlineStart)
            XCTAssertEqual(outlineCount, starts.keys.filter { $0 >= outlineStart && $0 < outlineStart + outlineLength }.count)
        }
        XCTAssertEqual(data.count, r.position)
        // Page ranges follow each other from the first page's object (offsets in the tables leave out the hint stream).
        var pageStart = Array(repeating: 0, count: pages)
        pageStart[0] = firstAt + hintLength
        XCTAssertEqual(offsetOf[lin["O"] ?? 0], pageStart[0])
        for p in stride(from: 1, to: pages, by: 1) { pageStart[p] = pageStart[p - 1] + lengths[p - 1] }
        XCTAssertEqual(lin["E"], pageStart[0] + lengths[0])
        if pages > 1 { XCTAssertEqual(offsetOf[document.pages[1].reference.number], lin["E"]) }
        // The groups: the first page's objects one by one, then the shared section's.
        var groupObjects: [Int] = []
        var cursor = pageStart[0]
        for g in 0..<groups.count {
            if g == sharedFirstPage { cursor = sharedFirstAt + hintLength }
            let number = starts[cursor]
            XCTAssertNotNil(number, "group \(g) starts at an object")
            XCTAssertEqual(groups[g], lengthOf(number ?? 0))
            groupObjects.append(number ?? 0)
            cursor += groups[g]
        }
        if sharedTotal > sharedFirstPage { XCTAssertEqual(sharedFirst, groupObjects[sharedFirstPage]) }
        for p in 0..<pages {
            let end = pageStart[p] + lengths[p]
            let inside = sortedStarts.filter { $0 >= pageStart[p] && $0 < end }.compactMap { starts[$0] }
            XCTAssertEqual(objects[p], inside.count)
            XCTAssertEqual(document.pages[p].reference.number, inside.first)
            let reached = reach(document, document.pages[p].reference.number).filter { !inside.contains($0) }.sorted()
            let listed = ids[p].map { groupObjects[$0] }.sorted()
            // What the page uses is in its range, in a group, in the document-level section before the hint
            // stream, or among the objects that follow the shared section.
            XCTAssertTrue(Set(listed).isSubset(of: Set(reached)), "page \(p): listed \(listed), reached \(reached)")
            for n in reached where !listed.contains(n) {
                XCTAssertTrue((offsetOf[n] ?? 0) < (lin["H0"] ?? 0) || (offsetOf[n] ?? 0) >= cursor, "page \(p): object \(n) is unlisted but in the page sections")
            }
            if p == 0 { XCTAssertTrue(ids[p].isEmpty) }
            let contents = contentNumbers(document, document.pages[p]).filter { inside.contains($0) }
            if let firstContent = contents.first, let lastContent = contents.last {
                XCTAssertEqual((offsetOf[firstContent] ?? 0) - pageStart[p], offsets[p])
                XCTAssertEqual((offsetOf[lastContent] ?? 0) + lengthOf(lastContent) - (offsetOf[firstContent] ?? 0), spans[p])
            } else {
                XCTAssertEqual(0, offsets[p])
                XCTAssertEqual(0, spans[p])
            }
        }
    }

    private static func contentNumbers(_ document: PdfDocument, _ page: PdfPage) -> [Int] {
        var found: [Int] = []
        var contents = page.dictionary["Contents"]
        if let reference = contents as? PdfReference {
            found.append(reference.number)
            contents = document.get(reference.number)
        }
        if let array = contents as? PdfArray {
            for case let item as PdfReference in array.items { found.append(item.number) }
        }
        return found
    }

    /// The objects a page uses: all it reaches except the other pages and its own /Parent.
    static func reach(_ document: PdfDocument, _ pageNumber: Int) -> Set<Int> {
        let pages = Set(document.pages.map { $0.reference.number })
        var seen: Set<Int> = [pageNumber]
        var todo: [PdfObject] = []
        func push(_ value: PdfObject?, _ top: Bool) {
            switch value {
            case let r as PdfReference:
                if !pages.contains(r.number), seen.insert(r.number).inserted, let target = document.get(r.number) { todo.append(target) }
            case let a as PdfArray:
                for i in a.items { push(i, false) }
            case let s as PdfStream:
                push(s.dictionary, false)
            case let d as PdfDictionary:
                for (key, v) in d.entries where !(top && key == "Parent") { push(v, false) }
            default:
                break
            }
        }
        push(document.get(pageNumber), true)
        while let item = todo.popLast() { push(item, false) }
        seen.remove(pageNumber)
        return seen
    }

    private struct BitReader {
        let data: [UInt8]
        private var bit = 0

        init(_ data: [UInt8]) { self.data = data }

        var position: Int { (bit + 7) / 8 }

        mutating func read(_ bits: Int) -> Int {
            var value = 0
            for _ in 0..<bits {
                let byte = bit >> 3 < data.count ? data[bit >> 3] : 0
                value = value << 1 | Int((byte >> UInt8(7 - (bit & 7))) & 1)
                bit += 1
            }
            return value
        }

        mutating func align() { bit = (bit + 7) & ~7 }
    }
}
