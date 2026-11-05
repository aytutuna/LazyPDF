import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/ScanFieldDetectorTests.cs: the same cases. `ScanFixtures` holds the two helpers of
// the C# OcrKit that these tests use (Scan and Pages), so that they do not wait for the Ocr layer; the noise of the
// scanned sheet comes from a port of System.Random(7).

private enum ScanFixtures {
    static let helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"

    static func scanBytes(_ count: Int = 1, pageEntries: String = "", content: String = "q 400 0 0 600 0 0 cm /Im1 Do Q") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<count).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(count) /MediaBox [0 0 400 600]>>")
        let image = 3 + 2 * count
        for i in 0..<count {
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + count + i) 0 R /Resources <</XObject <</Im1 \(image) 0 R>> /Font <</F1 \(image + 1) 0 R>>>> \(pageEntries)>>")
        }
        for i in 0..<count { pdf.stream(3 + count + i, "", content) }
        pdf.stream(image, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0x20, 0x80, 0xC0, 0xF0])
        pdf.obj(image + 1, helvetica)
        return pdf.finish()
    }

    static func scan(_ count: Int = 1, pageEntries: String = "", content: String = "q 400 0 0 600 0 0 cm /Im1 Do Q") throws -> PdfDocument {
        try PdfDocument.open(scanBytes(count, pageEntries: pageEntries, content: content))
    }

    /// Pages whose content is given, 400 by 600, with Helvetica as /F1.
    static func pages(_ contents: String...) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = contents.indices.map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(contents.count) /MediaBox [0 0 400 600]>>")
        let font = 3 + 2 * contents.count
        for i in contents.indices {
            pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Contents \(3 + contents.count + i) 0 R /Resources <</Font <</F1 \(font) 0 R>>>>>>")
        }
        for (i, content) in contents.enumerated() { pdf.stream(3 + contents.count + i, "", content) }
        pdf.obj(font, helvetica)
        return try PdfDocument.open(pdf.finish())
    }
}

/// System.Random with a seed (the subtractive generator of Knuth's), as the C# sheet uses it.
private struct SheetRandom {
    private var seeds = [Int32](repeating: 0, count: 56)
    private var inext = 0
    private var inextp = 21

    init(_ seed: Int) {
        var mj: Int32 = 161_803_398 &- Int32(abs(seed))
        seeds[55] = mj
        var mk: Int32 = 1
        var ii = 0
        for _ in 1..<55 {
            ii += 21
            if ii >= 55 { ii -= 55 }
            seeds[ii] = mk
            mk = mj &- mk
            if mk < 0 { mk = mk &+ Int32.max }
            mj = seeds[ii]
        }
        for _ in 1..<5 {
            for i in 1..<56 {
                var n = i + 30
                if n >= 55 { n -= 55 }
                seeds[i] = seeds[i] &- seeds[1 + n]
                if seeds[i] < 0 { seeds[i] = seeds[i] &+ Int32.max }
            }
        }
    }

    private mutating func sample() -> Double {
        var a = inext + 1
        if a >= 56 { a = 1 }
        var b = inextp + 1
        if b >= 56 { b = 1 }
        var result = seeds[a] &- seeds[b]
        if result == Int32.max { result -= 1 }
        if result < 0 { result = result &+ Int32.max }
        seeds[a] = result
        inext = a
        inextp = b
        return Double(result) * (1.0 / Double(Int32.max))
    }

    mutating func nextDouble() -> Double { sample() }

    mutating func next(_ maxValue: Int) -> Int { Int(sample() * Double(maxValue)) }
}

final class ScanFieldDetectorTests: XCTestCase {
    private static let dpi = 150.0
    private static let k = dpi / 72

    // A 400 by 600 point page as a scanner would give it: paper, ink, and what goes wrong with both.
    private final class Sheet {
        private var gray: [UInt8]
        private let width = Int(400 * ScanFieldDetectorTests.k)
        private let height = Int(600 * ScanFieldDetectorTests.k)
        private var random = SheetRandom(7)
        private let skew: Double
        private let ink: UInt8

        init(skewDegrees: Double = 0, ink: UInt8 = 20, paper: UInt8 = 245) {
            skew = tan(skewDegrees * Double.pi / 180)
            self.ink = ink
            gray = [UInt8](repeating: paper, count: Int(400 * ScanFieldDetectorTests.k) * Int(600 * ScanFieldDetectorTests.k))
        }

        private func put(_ x: Int, _ y: Int) {
            let row = y + Int((Double(x) * skew).rounded(.toNearestOrEven))
            if x >= 0 && row >= 0 && x < width && row < height { gray[row * width + x] = ink }
        }

        private func fill(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            let k = ScanFieldDetectorTests.k
            var y = Int((y1 * k).rounded(.toNearestOrEven))
            while y < Int((y2 * k).rounded(.toNearestOrEven)) {
                var x = Int((x1 * k).rounded(.toNearestOrEven))
                while x < Int((x2 * k).rounded(.toNearestOrEven)) {
                    put(x, y)
                    x += 1
                }
                y += 1
            }
        }

        @discardableResult
        func line(_ x1: Double, _ x2: Double, _ y: Double, _ thick: Double = 0.7) -> Sheet {
            fill(x1, y, x2, y + thick)
            return self
        }

        @discardableResult
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ thick: Double = 0.7) -> Sheet {
            line(x, x + w, y, thick).line(x, x + w, y + h - thick, thick)
            fill(x, y, x + thick, y + h)
            fill(x + w - thick, y, x + w, y + h)
            return self
        }

        @discardableResult
        func rule(_ x: Double, _ y1: Double, _ y2: Double, _ thick: Double = 0.7) -> Sheet {
            fill(x, y1, x + thick, y2)
            return self
        }

        // Words as short broken strokes on a row, the way type or handwriting looks to a run-length scan.
        @discardableResult
        func scribble(_ x: Double, _ y: Double, _ w: Double, _ h: Double = 9) -> Sheet {
            var cx = x
            while cx < x + w {
                let top = y + random.nextDouble() * 2, height = h - 2 + random.nextDouble() * 3
                fill(cx, top, cx + 0.8, top + height)
                if random.nextDouble() < 0.35 { fill(cx, top + height / 2, cx + 2.5 + random.nextDouble() * 2, top + height / 2 + 0.7) }
                cx += 1.2 + random.nextDouble() * 4
            }
            return self
        }

        @discardableResult
        func paragraph(_ x: Double, _ y: Double, _ w: Double, _ lines: Int) -> Sheet {
            for i in 0..<lines { scribble(x, y + Double(i) * 13, w * (0.7 + 0.3 * random.nextDouble())) }
            return self
        }

        @discardableResult
        func speckle(_ density: Double) -> Sheet {
            var i = 0
            while Double(i) < Double(gray.count) * density {
                gray[random.next(gray.count)] = ink
                i += 1
            }
            return self
        }

        func image() -> PdfRgbaImage {
            var rgba = [UInt8](repeating: 255, count: gray.count * 4)
            for i in 0..<gray.count {
                rgba[i * 4] = gray[i]
                rgba[i * 4 + 1] = gray[i]
                rgba[i * 4 + 2] = gray[i]
            }
            return PdfRgbaImage(width, height, rgba)
        }
    }

    private final class SheetRenderer: PageRenderer {
        let sheet: Sheet

        init(_ sheet: Sheet) {
            self.sheet = sheet
        }

        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { sheet.image() }
    }

    private final class NoRenderer: PageRenderer {
        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    }

    private final class CountingRenderer: PageRenderer {
        var calls: [Int] = []

        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
            calls.append(pageIndex)
            return nil
        }
    }

    private func page(_ labels: (text: String, x: Double, y: Double)...) throws -> PdfDocument {
        var content = "q 400 0 0 600 0 0 cm /Im1 Do Q"
        for label in labels { content += " BT 3 Tr /F1 10 Tf 1 0 0 1 \(label.x) \(600 - label.y - 8) Tm (\(label.text)) Tj ET" }
        return try ScanFixtures.scan(1, content: content)
    }

    private func hits(_ p: FieldProposal, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Bool {
        // The proposal in points from the top; it must cover at least half of the expected box and not be more than twice its area.
        let left = p.rect.left, right = p.rect.right, top = 600 - p.rect.top, bottom = 600 - p.rect.bottom
        let overlap = max(0, min(right, x + w) - max(left, x)) * max(0, min(bottom, y + h) - max(top, y))
        let area = (right - left) * (bottom - top)
        return overlap >= 0.5 * w * h && area <= 2 * w * h
    }

    // What the form below has, in points from the top left: the lines and boxes a person fills in, and the ones they must not.
    private let expected: [(kind: FieldKind, x: Double, y: Double, w: Double, h: Double)] = [
        (.text, 90, 62, 200, 16),
        (.text, 90, 102, 250, 16),
        (.text, 90, 142, 150, 16),
        (.checkBox, 50, 200, 12, 12),
        (.checkBox, 50, 225, 12, 12),
        (.text, 50, 270, 300, 24),
        (.text, 50, 320, 120, 18),
        (.text, 220, 320, 130, 18),
    ]

    private func filledForm(skew: Double = 0, ink: UInt8 = 20, paper: UInt8 = 245) -> Sheet {
        let sheet = Sheet(skewDegrees: skew, ink: ink, paper: paper)
        sheet.scribble(60, 20, 150, 12).line(60, 340, 36)                          // a heading with its rule: not a blank
        sheet.line(90, 290, 78).line(90, 340, 118).line(90, 240, 158)              // three blanks
        sheet.scribble(95, 168, 90)                                                // a line already written on
        sheet.line(90, 240, 182)
        sheet.box(50, 200, 12, 12).box(50, 225, 12, 12)                            // check boxes
        sheet.box(50, 270, 300, 24)                                                // a box
        sheet.box(50, 320, 300, 18).rule(170, 320, 338).rule(220, 320, 338).scribble(180, 322, 30, 12)   // a row of three cells; the middle one is written in
        sheet.paragraph(50, 380, 300, 8)                                           // text
        return sheet
    }

    private func isExpected(_ p: FieldProposal) -> Bool {
        expected.contains { p.kind == $0.kind && hits(p, $0.x, $0.y, $0.w, $0.h) }
    }

    private func score(_ found: [FieldProposal]) -> (found: Int, missed: Int, extra: Int) {
        let hit = expected.filter { e in found.contains { $0.kind == e.kind && hits($0, e.x, e.y, e.w, e.h) } }.count
        let extra = found.filter { !isExpected($0) }.count
        return (hit, expected.count - hit, extra)
    }

    private func run(_ name: String, _ sheet: Sheet) throws -> (found: Int, missed: Int, extra: Int) {
        let found = FieldDetector.detect(try page(), 0, SheetRenderer(sheet))
        let result = score(found)
        for p in found where !isExpected(p) {
            print("  extra \(p.kind) \(Int(p.rect.left)) \(Int(600 - p.rect.top)) \(Int(p.rect.width))x\(Int(p.rect.height)) cells \(p.cells)")
        }
        print("\(name): \(result.found) of \(expected.count) found, \(result.missed) missed, \(result.extra) extra (\(found.count) proposed)")
        return result
    }

    func test_aCleanScanGivesItsLinesBoxesAndChecks() throws {
        let result = try run("clean", filledForm())

        XCTAssertEqual(result.missed, 0)
        XCTAssertEqual(result.extra, 0)
    }

    func test_theTextLayerNamesTheBlanks() throws {
        let found = FieldDetector.detect(try page(("Name", 50, 62), ("Address", 40, 102), ("I agree", 68, 200)), 0, SheetRenderer(filledForm()))

        for p in found { XCTAssertTrue(p.fromPixels) }
        XCTAssertEqual(found.first { hits($0, 90, 62, 200, 16) }?.label, "Name")
        XCTAssertEqual(found.first { hits($0, 90, 102, 250, 16) }?.label, "Address")
        let check = try XCTUnwrap(found.first { $0.kind == .checkBox && hits($0, 50, 200, 12, 12) })
        XCTAssertEqual(check.label, "I agree")
        XCTAssertEqual(check.name, "I agree")
        XCTAssertEqual(found.count, Set(found.map { $0.name }).count)
    }

    func test_specklesFaintInkAndASlightTurnStillWork() throws {
        let noisy = try run("speckle", filledForm().speckle(0.004))
        let faint = try run("faint ink", filledForm(ink: 130, paper: 235))
        let turned = try run("0.1 degree", filledForm(skew: 0.1))

        XCTAssertTrue(noisy.missed <= 1 && noisy.extra <= 1, "speckle")
        XCTAssertTrue(faint.missed <= 1 && faint.extra <= 1, "faint ink")
        XCTAssertTrue(turned.missed <= 1 && turned.extra <= 1, "turned by a tenth of a degree")
    }

    func test_aTurnOfAFifthOfADegreeIsTheLimit() throws {
        let a = try run("0.2 degree", filledForm(skew: 0.2))
        let b = try run("0.5 degree", filledForm(skew: 0.5))

        // There is no deskew: past a fifth of a degree the longer rules are given up, and nothing is made up in their place.
        XCTAssertEqual(a.missed, 0)
        XCTAssertEqual(a.extra, 0)
        XCTAssertEqual(b.extra, 0)
    }

    func test_aComboOfEqualBoxesIsOneComb() throws {
        let sheet = Sheet()
        for i in 0..<8 { sheet.box(60 + Double(i) * 20, 100, 20, 24) }

        let found = FieldDetector.detect(try page(), 0, SheetRenderer(sheet))

        XCTAssertEqual(found.count, 1)
        let comb = try XCTUnwrap(found.first)
        XCTAssertEqual(comb.cells, 8)
        XCTAssertEqual(comb.kind, .text)
        XCTAssertTrue(comb.rect.width >= 159 && comb.rect.width <= 161)
    }

    func test_blankAndTextOnlyPagesGiveNothing() throws {
        XCTAssertTrue(FieldDetector.detect(try page(), 0, SheetRenderer(Sheet())).isEmpty)
        XCTAssertTrue(FieldDetector.detect(try page(), 0, SheetRenderer(Sheet().paragraph(40, 40, 320, 30).speckle(0.003))).isEmpty)
    }

    func test_proposalsOverAFieldTheFileHasAreLeftOut() throws {
        let document = try page()
        let sheet = filledForm()
        let form = PdfForm.read(document)
        try form.addField(FieldSpec(.text, "name", 0, PdfRect(90, 600 - 78 + 1, 290, 600 - 78 + 17)))

        let found = FieldDetector.detect(document, 0, SheetRenderer(sheet))

        XCTAssertFalse(found.contains { hits($0, 90, 62, 200, 16) })
    }

    func test_aPageThatDoesNotDrawGivesNothing() throws {
        XCTAssertTrue(FieldDetector.detect(try page(), 0, NoRenderer()).isEmpty)
    }

    func test_aTextPageIsLeftToTheVectorDetector() throws {
        let renderer = CountingRenderer()
        let document = try ScanFixtures.pages("BT /F1 12 Tf 50 500 Td (Name:) Tj ET 0.5 w 100 498 m 300 498 l S")

        let found = try FieldDetector.detect(document, renderer)

        XCTAssertEqual(found.count, 1)
        XCTAssertFalse(found[0].fromPixels)
        XCTAssertTrue(renderer.calls.isEmpty)
    }
}
