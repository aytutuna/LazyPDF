import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/OfficeLayoutTests.cs and reads the same golden files.

final class OfficeLayoutTests: XCTestCase {
    private static let words = "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega"
    private static let small = LayoutGeometry(width: 100, height: 100, top: 10, right: 10, bottom: 10, left: 10)

    private func num(_ value: Double) -> String {
        String(format: "%.2f", (value * 100).rounded(.toNearestOrAwayFromZero) / 100 + 0.0)
    }

    private func styleName(_ style: FontStyles) -> String {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): return "Bold, Italic"
        case (true, false): return "Bold"
        case (false, true): return "Italic"
        default: return "Regular"
        }
    }

    private func dump(_ document: LayoutDocument) throws -> String { try dump(document, OfficeLayoutSpec.fonts()) }

    func dump(_ document: LayoutDocument, _ fonts: FontSource) throws -> String {
        let layout = try Paginator(document, LayoutFonts(fonts)).run()
        var contents: [[UInt8]] = []
        _ = try OfficePdfWriter.create(document, fonts) { _, bytes in contents.append(bytes) }
        var output = ""
        for i in 0..<layout.pages.count {
            let page = layout.pages[i]
            output += "page \(i + 1) \(num(page.width)) \(num(page.height))\n"
            for box in page.boxes {
                switch box {
                case .text(let t):
                    output += "text \(num(t.x)) \(num(t.baseline)) \(t.family)/\(styleName(t.style)) \(num(t.size)) \(String(format: "%06x", t.color)) +\(num(t.spaceExtra))\(t.rightToLeft ? " rtl" : "") \"\(OfficeLayoutSpec.escape(t.text))\"\n"
                case .image(let img):
                    output += "image \(num(img.x)) \(num(img.y)) \(num(img.width)) \(num(img.height))\n"
                case .rect(let r):
                    output += "rect \(num(r.x)) \(num(r.y)) \(num(r.width)) \(num(r.height)) \(String(format: "%06x", r.color))\n"
                case .path:
                    break
                }
            }
            var text = Latin1.string(contents[i])
            while text.hasSuffix("\n") { text.removeLast() }
            for line in text.components(separatedBy: "\n") { output += "| \(line)\n" }
        }
        for s in layout.skipped { output += "skipped \(s.kind) \(s.count)\n" }
        if !layout.missing.isEmpty { output += "missing " + layout.missing.map { String($0, radix: 16) }.joined(separator: " ") + "\n" }
        return output
    }

    func test_layoutGoldenFile() throws {
        var output = ""
        for (name, document) in try OfficeLayoutSpec.read(try Golden.input("office-layout", "layout-input.txt")) {
            output += "> \(name)\n" + (try dump(document))
        }
        try Golden.check("office-layout", "layout-output.txt", output)
    }

    func test_rightToLeftLayoutGoldenFile() throws {
        var output = ""
        for (name, document) in try OfficeLayoutSpec.read(try Golden.input("office-layout", "rtl-input.txt")) {
            output += "> \(name)\n" + (try dump(document, OfficeLayoutSpec.scriptFonts()))
        }
        try Golden.check("office-layout", "rtl-output.txt", output)
    }

    private func rtlDocument(_ text: String, rtl: Bool, align: LayoutAlign = .left) -> LayoutDocument {
        let made = paragraph(text, align: align)
        made.rightToLeft = rtl
        return single(LayoutGeometry(width: 200, height: 200, top: 20, right: 20, bottom: 20, left: 20), [made])
    }

    func test_aRightToLeftParagraphStartsAtTheRightEdgeAndItsLinesStaySortedByPlace() throws {
        let fonts = LayoutFonts(OfficeLayoutSpec.scriptFonts())
        let document = rtlDocument("אבג דהו זחט יכל מנס עפצ קרש תאב גדה וזח", rtl: true, align: .right)
        let layout = try Paginator(document, fonts).run()
        var texts: [PlacedText] = []
        for case .text(let t) in layout.pages[0].boxes { texts.append(t) }
        XCTAssertGreaterThan(texts.count, 1)
        XCTAssertTrue(texts.allSatisfy { $0.rightToLeft })
        let face = fonts.find(OfficeFontSource.defaultFamily, [])!
        for baseline in Set(texts.map { $0.baseline }) {
            let ends = texts.filter { $0.baseline == baseline }.map { t in t.x + t.text.unicodeScalars.reduce(0.0) { $0 + face.advance(Int($1.value)) } * t.size }
            XCTAssertEqual(ends.max()!, 180, accuracy: 0.01)
        }
    }

    func test_rightToLeftTextIsWrittenInDisplayOrderAndReadsBackInLogicalOrder() throws {
        let text = "אבג abc דהו 12 זחט"
        let made = try OfficePdfWriter.create(rtlDocument(text, rtl: true, align: .right), OfficeLayoutSpec.scriptFonts())
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertEqual(TextPage.create(pdf, pdf.pages[0]).text.replacingOccurrences(of: "\n", with: " "), text)
        XCTAssertTrue(made.missing.isEmpty)
    }

    func test_aLeftToRightParagraphWithoutHebrewLaysOutAsBefore() throws {
        let layout = try Paginator(rtlDocument("abc def", rtl: false), LayoutFonts(OfficeLayoutSpec.scriptFonts())).run()
        var texts: [PlacedText] = []
        for case .text(let t) in layout.pages[0].boxes { texts.append(t) }
        XCTAssertEqual(texts.count, 1)
        XCTAssertFalse(texts[0].rightToLeft)
        XCTAssertEqual(texts[0].x, 20)
    }

    // Raises and nudges every glyph, as a platform shaper places marks.
    private final class OffsetScriptFont: FontSource, Shaper {
        private let font = OfficeLayoutSpec.ScriptFont()

        func find(_ family: String, _ style: FontStyles) -> FontFile? { font.find(family, style) }

        func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
            CmapShaper().shape(text, font, rightToLeft: rightToLeft, language: language)!.map {
                ShapedGlyph(glyph: $0.glyph, advance: $0.advance, xOffset: 50, yOffset: 100, cluster: $0.cluster)
            }
        }
    }

    // Joined forms are narrower than the isolated letters.
    private final class NarrowScriptFont: FontSource, Shaper {
        private let font = OfficeLayoutSpec.ScriptFont()

        func find(_ family: String, _ style: FontStyles) -> FontFile? { font.find(family, style) }

        func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
            CmapShaper().shape(text, font, rightToLeft: rightToLeft, language: language)!.map {
                ShapedGlyph(glyph: $0.glyph, advance: $0.advance / 2, xOffset: $0.xOffset, yOffset: $0.yOffset, cluster: $0.cluster)
            }
        }
    }

    func test_arabicIsMeasuredWithTheAdvancesTheShaperDraws() throws {
        let fonts = OfficeFontSource(installed: NarrowScriptFont(), bundled: nil)
        let layout = try Paginator(rtlDocument("ابلم", rtl: true, align: .right), LayoutFonts(fonts)).run()
        var texts: [PlacedText] = []
        for case .text(let t) in layout.pages[0].boxes { texts.append(t) }
        XCTAssertEqual(texts.count, 1)
        let face = LayoutFonts(fonts).find(OfficeFontSource.defaultFamily, [])!
        let isolated = texts[0].text.unicodeScalars.reduce(0.0) { $0 + face.advance(Int($1.value)) } * texts[0].size
        XCTAssertEqual(texts[0].x, 180 - isolated / 2, accuracy: 0.01)
    }

    private func drawn(_ align: LayoutAlign, _ text: String) throws -> String {
        var contents: [[UInt8]] = []
        let fonts = OfficeFontSource(installed: OffsetScriptFont(), bundled: nil)
        _ = try OfficePdfWriter.create(rtlDocument(text, rtl: false, align: align), fonts) { _, bytes in contents.append(bytes) }
        return String(decoding: contents[0], as: UTF8.self)
    }

    func test_shaperOffsetsReachTheTextWrittenForALeftToRightLine() throws {
        XCTAssertTrue(try drawn(.left, "abc def").contains(" Ts"))
    }

    func test_shaperOffsetsReachJustifiedLinesToo() throws {
        let content = try drawn(.justify, "abc def abc def abc def abc def abc def abc def abc def abc def")
        XCTAssertTrue(content.contains(" Ts"))
        XCTAssertTrue(content.contains("TJ"))
    }

    func test_tablesGoldenFile() throws {
        var output = ""
        for (name, document) in try OfficeLayoutSpec.read(try Golden.input("office-layout", "tables-input.txt")) {
            output += "> \(name)\n" + (try dump(document))
        }
        try Golden.check("office-layout", "tables-output.txt", output)
    }

    func test_lineBreakGoldenFile() throws {
        var output = ""
        for line in try Golden.input("office-layout", "linebreak-input.txt").components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("# ") { continue }
            let codes = OfficeLayoutSpec.unescape(line).unicodeScalars.map { Int($0.value) }
            let breaks = LineBreaker.opportunities(codes)
            var chunk = String.UnicodeScalarView()
            output += "> \(line)\n< "
            for i in 0..<codes.count {
                if breaks[i] {
                    output += OfficeLayoutSpec.escape(String(chunk)) + "|"
                    chunk = String.UnicodeScalarView()
                }
                chunk.append(Unicode.Scalar(UInt32(codes[i]))!)
            }
            output += OfficeLayoutSpec.escape(String(chunk)) + "\n"
        }
        try Golden.check("office-layout", "linebreak-output.txt", output)
    }

    private func single(_ page: LayoutGeometry, _ blocks: [LayoutBlock]) -> LayoutDocument {
        let section = LayoutSection()
        section.page = page
        section.blocks = blocks
        let document = LayoutDocument()
        document.sections = [section]
        return document
    }

    private func paragraph(_ text: String, align: LayoutAlign = .left, keep: Bool = false, widow: Bool = true, size: Double = 11, after: Double = 0) -> LayoutParagraph {
        let run = LayoutRun()
        run.text = text
        run.size = size
        let made = LayoutParagraph()
        made.runs = [run]
        made.align = align
        made.keepWithNext = keep
        made.widowControl = widow
        made.after = after
        return made
    }

    private func layout(_ document: LayoutDocument) throws -> LayoutResult {
        try Paginator(document, LayoutFonts(OfficeLayoutSpec.fonts())).run()
    }

    private func texts(_ page: LayoutPage) -> [PlacedText] {
        page.boxes.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }

    func test_linesStayInsideTheTextArea() throws {
        let result = try layout(single(LayoutGeometry(width: 200, height: 200, top: 20, right: 20, bottom: 20, left: 20), [paragraph(Self.words + " " + Self.words)]))
        let face = try XCTUnwrap(LayoutFonts(OfficeLayoutSpec.fonts()).find("Carlito", .regular))
        for t in texts(result.pages[0]) {
            XCTAssertTrue(t.x >= 20 && t.x <= 180)
            var ink = Array(t.text.unicodeScalars)
            while ink.last == " " { ink.removeLast() }
            XCTAssertLessThanOrEqual(t.x + ink.reduce(0.0) { $0 + face.advance(Int($1.value)) } * t.size, 180.01, t.text)
        }
    }

    func test_justifiedLinesReachBothEdgesExceptTheLast() throws {
        let geometry = LayoutGeometry(width: 200, height: 200, top: 20, right: 20, bottom: 20, left: 20)
        let result = try layout(single(geometry, [paragraph(Self.words, align: .justify)]))
        let face = try XCTUnwrap(LayoutFonts(OfficeLayoutSpec.fonts()).find("Carlito", .regular))
        let lines = texts(result.pages[0])
        XCTAssertGreaterThan(lines.count, 2)
        for t in lines.dropLast() {
            var ink = Array(t.text.unicodeScalars)
            while ink.last == " " { ink.removeLast() }
            let ends = t.x + ink.reduce(0.0) { $0 + face.advance(Int($1.value)) } * t.size + Double(ink.filter { $0 == " " }.count) * t.spaceExtra
            XCTAssertEqual(ends, 180, accuracy: 0.001)
        }
        XCTAssertEqual(lines.last!.spaceExtra, 0)
    }

    func test_widowControlLeavesAtLeastTwoLinesOnEitherSide() throws {
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        let counts = try layout(single(Self.small, [paragraph(text)])).pages.map { texts($0).count }
        XCTAssertGreaterThan(counts.count, 1)
        for c in counts { XCTAssertGreaterThanOrEqual(c, 2) }
        let loose = try layout(single(Self.small, [paragraph(text, widow: false)]))
        XCTAssertEqual(loose.pages.reduce(0) { $0 + texts($1).count }, counts.reduce(0, +))
    }

    func test_keepWithNextMovesTheHeadingToThePageOfItsParagraph() throws {
        let filler = paragraph(Array(repeating: "word", count: 26).joined(separator: " "))
        let next = paragraph("one two three four five six")
        let result = try layout(single(Self.small, [filler, paragraph("Heading", keep: true), next]))
        XCTAssertEqual(result.pages.count, 3)
        XCTAssertEqual(texts(result.pages[2]).first?.text, "Heading")
        let loose = try layout(single(Self.small, [filler, paragraph("Heading"), next]))
        XCTAssertTrue(texts(loose.pages[1]).contains { $0.text == "Heading" })
    }

    func test_pageBreakStartsAPage() throws {
        let result = try layout(single(Self.small, [paragraph("One"), LayoutPageBreak(), paragraph("Two")]))
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertEqual(texts(result.pages[0]).map(\.text), ["One"])
        XCTAssertEqual(texts(result.pages[1]).map(\.text), ["Two"])
    }

    func test_spaceBeforeIsKeptAfterAHardBreakAndDroppedAfterASoftOne() throws {
        let run = LayoutRun()
        run.text = "Next"
        let spaced = LayoutParagraph()
        spaced.runs = [run]
        spaced.before = 20
        let hard = try layout(single(Self.small, [paragraph("A"), LayoutPageBreak(), spaced]))
        let plain = try layout(single(Self.small, [paragraph("A"), LayoutPageBreak(), paragraph("Next")]))
        XCTAssertEqual(texts(plain.pages[1])[0].baseline + 20, texts(hard.pages[1])[0].baseline, accuracy: 1e-6)

        let filler = paragraph(Array(repeating: "word", count: 44).joined(separator: " "))
        let soft = try layout(single(Self.small, [filler, spaced]))
        let start = texts(soft.pages[soft.pages.count - 1])[0]
        XCTAssertEqual(start.text, "Next")
        XCTAssertEqual(start.baseline, texts(plain.pages[0])[0].baseline, accuracy: 1e-6)
    }

    func test_headerAndFooterCarryThePageNumberAndTheCount() throws {
        func part(_ text: String = "", _ field: LayoutField = .none) -> LayoutRun {
            let run = LayoutRun()
            run.text = text
            run.field = field
            return run
        }
        let footer = LayoutParagraph()
        footer.runs = [part("Page "), part("", .pageNumber), part(" of "), part("", .pageCount)]
        let document = single(Self.small, [paragraph("One"), LayoutPageBreak(), paragraph("Two"), LayoutPageBreak(), paragraph("Three")])
        document.sections[0].footer.append(footer)
        let made = try OfficePdfWriter.create(document, OfficeLayoutSpec.fonts())
        XCTAssertEqual(made.pages, 3)
        let pdf = try PdfDocument.open(made.bytes)
        for i in 0..<3 { XCTAssertTrue(TextPage.create(pdf, pdf.pages[i]).text.contains("Page \(i + 1) of 3")) }
    }

    func test_textStaysSelectableAndTheFileReopens() throws {
        let sentence = "Dünya ğ ş ı İ çok güzel, shall we meet at noon"
        let document = single(LayoutGeometry(width: 200, height: 200, top: 20, right: 20, bottom: 20, left: 20), [paragraph(sentence, align: .justify)])
        let made = try OfficePdfWriter.create(document, OfficeLayoutSpec.fonts())
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertEqual(TextPage.create(pdf, pdf.pages[0]).text.replacingOccurrences(of: "\n", with: " "), sentence)
        XCTAssertTrue(made.missing.isEmpty)
    }

    func test_scriptsThatNeedShapingAreReportedAndGlyphGapsAreListed() throws {
        let document = single(Self.small, [paragraph("abc שלום"), paragraph("السلام"), paragraph("नमस्ते"), paragraph("中")])
        document.skipped.append(SkippedFeature("charts", 1))
        let made = try OfficePdfWriter.create(document, OfficeLayoutSpec.fonts())
        XCTAssertEqual(made.skipped, [SkippedFeature("charts", 1), SkippedFeature(SkippedKinds.complexScript, 1)])
        XCTAssertTrue(made.missing.contains(0x4E2D))
    }

    func test_aBandThatLeavesNoBodyGivesWayToTheMargins() throws {
        let document = single(Self.small, [paragraph("Body")])
        document.sections[0].header.append(paragraph("Header", size: 90))
        let result = try layout(document)
        XCTAssertEqual(texts(result.pages[0]).filter { $0.size == 11 }.map(\.text), ["Body"])
    }

    func test_aTallPictureOnAnExactLineIsCutAtTheLineTop() throws {
        let run = LayoutRun()
        run.picture = LayoutPicture(PictureFile([0xFF, 0xD8, 0xFF, 0xD9]), 50, 50)
        let made = LayoutParagraph()
        made.runs = [run]
        made.rule = .exact
        made.lineSpacing = 12
        let result = try layout(single(Self.small, [made]))
        let images: [PlacedImage] = result.pages[0].boxes.compactMap { if case .image(let i) = $0 { return i } else { return nil } }
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(image.y, Self.small.top, accuracy: 1e-6)
        XCTAssertGreaterThan(image.height, 1)
        XCTAssertLessThanOrEqual(image.height, 12)
        XCTAssertEqual(50 - image.height, image.source.cropTop * 50, accuracy: 1e-6)
        XCTAssertEqual(image.width, 50)
    }

    func test_exactSpacingSetsTheLineHeight() throws {
        let made = paragraph(Array(repeating: "word", count: 12).joined(separator: " "))
        made.rule = .exact
        made.lineSpacing = 20
        let result = try layout(single(LayoutGeometry(width: 100, height: 400, top: 10, right: 10, bottom: 10, left: 10), [made]))
        let baselines = texts(result.pages[0]).map(\.baseline)
        XCTAssertGreaterThan(baselines.count, 2)
        for k in 1..<baselines.count { XCTAssertEqual(baselines[k] - baselines[k - 1], 20, accuracy: 1e-6) }
    }

    func test_theTabAfterAListNumberRunsToItsStopOrTheHangingIndent() throws {
        let page = LayoutGeometry(width: 300, height: 200, top: 10, right: 10, bottom: 10, left: 10)
        func textX(_ left: Double, _ first: Double, _ stop: Double?) throws -> Double {
            let made = paragraph("1.\tword")
            made.left = left
            made.firstLine = first
            made.labelTab = stop
            let result = try layout(single(page, [made]))
            return try XCTUnwrap(texts(result.pages[0]).first { $0.text.contains("word") }).x
        }
        XCTAssertEqual(try textX(0, 0, 50), 10 + 50, accuracy: 0.01)
        XCTAssertEqual(try textX(40, -40, nil), 10 + 40, accuracy: 0.01)
        XCTAssertEqual(try textX(40, -40, 30), 10 + 30, accuracy: 0.01)
        XCTAssertEqual(try textX(0, 0, nil), 10 + 36, accuracy: 0.01)
    }

    func test_badGeometryAndRunawayLengthAreRefused() throws {
        let narrow = single(LayoutGeometry(width: 100, height: 100, top: 72, right: 40, bottom: 72, left: 50), [paragraph("x")])
        XCTAssertThrowsError(try OfficePdfWriter.create(narrow, OfficeLayoutSpec.fonts())) {
            XCTAssertEqual(($0 as? PdfReadException)?.problem, .unsupported)
        }
        let huge = single(LayoutGeometry(width: 100000, height: 100), [paragraph("x")])
        XCTAssertThrowsError(try OfficePdfWriter.create(huge, OfficeLayoutSpec.fonts())) { XCTAssertTrue($0 is PdfReadException) }

        let breaks: [LayoutBlock] = Array(repeating: LayoutPageBreak(), count: Paginator.maxPages + 1)
        XCTAssertThrowsError(try OfficePdfWriter.create(single(Self.small, breaks), OfficeLayoutSpec.fonts())) {
            XCTAssertEqual(($0 as? PdfReadException)?.problem, .unsupported)
        }
    }

    func test_anUnbrokenStringLongerThanTheLineIsCutAtTheEdge() throws {
        let result = try layout(single(Self.small, [paragraph(String(repeating: "W", count: 60))]))
        XCTAssertGreaterThan(texts(result.pages[0]).count, 3)
        XCTAssertEqual(result.pages.reduce(0) { $0 + texts($1).reduce(0) { $0 + $1.text.unicodeScalars.count } }, 60)
    }

    func test_withoutAnyFontTheDocumentIsRefused() throws {
        XCTAssertThrowsError(try OfficePdfWriter.create(single(Self.small, [paragraph("x")]), nil)) {
            XCTAssertEqual(($0 as? InvalidOperationException)?.message, ExportText.noFont)
        }
    }

    func test_cancellationStopsTheLayout() async {
        let document = single(Self.small, [paragraph("x")])
        let task = Task { () throws -> OfficePdf in
            while !Task.isCancelled { await Task.yield() }
            return try OfficePdfWriter.create(document, OfficeLayoutSpec.fonts())
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
