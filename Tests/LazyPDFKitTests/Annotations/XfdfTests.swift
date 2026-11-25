import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/XfdfTests.cs: the same cases. BadXmlIsDamagedNotACrash checks the problem
// only; the message of the C# is .NET's own.

final class XfdfTests: XCTestCase {
    private let day = DateTimeOffset(2026, 3, 1, 9, 0, 0)

    private func later(_ hours: Int) -> DateTimeOffset { DateTimeOffset(2026, 3, 1, 9 + hours, 0, 0) }

    private func marked() throws -> PdfDocument {
        let document = try AnnotationFixtures.blank(2)
        let writer = PdfAnnotationWriter(document)
        let page = document.pages[0]
        let note = try writer.addNote(page, PdfRect(50, 100, 70, 120), AnnotationInfo(author: "Ayşe", contents: "şiir & <tag>", subject: "Konu", date: day), icon: "Comment", color: [1, 0.5, 0])
        try PdfComments.reply(document, note, "yanıt", "Can", later(1))
        try writer.addTextMarkup(page, .highlight, [MarkupQuad.fromRect(PdfRect(50, 700, 150, 714)), MarkupQuad.fromRect(PdfRect(50, 680, 90, 694))],
                                 info: AnnotationInfo(author: "Ali"), style: AnnotationStyle(opacity: 0.5))
        try writer.addSquare(page, PdfRect(200, 200, 300, 260), style: AnnotationStyle(color: [0, 0, 1], width: 3, dash: [4, 2], fill: [1, 1, 0.5]))
        try writer.addCircle(page, PdfRect(200, 300, 300, 360), style: AnnotationStyle(cloud: 2))
        try writer.addLine(page, (10, 10), (110, 60), style: AnnotationStyle(width: 2), info: nil, start: .circle, end: .closedArrow)
        try writer.addPolygon(page, [(300, 400), (350, 450), (400, 400)])
        try writer.addPolyLine(page, [(300, 500), (350, 550), (400, 500)])
        try writer.addInk(page, [[(10, 300), (20, 320), (30, 310)], [(40, 300), (50, 320)]])
        try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "boxed text", font: FreeTextStyle(family: "Times New Roman", size: 14, font: .bold, textColor: [0, 0, 1], alignment: 1),
                               style: AnnotationStyle(color: [1, 0, 0], width: 2, fill: [1, 1, 0.8]), info: AnnotationInfo(author: "Ali"))
        try writer.addCaret(page, PdfRect(400, 100, 416, 116))
        try writer.addStamp(page, PdfRect(300, 600, 500, 660), "Draft")
        return document
    }

    // XFDF only has RGB, so a gray comes back as three equal numbers.
    private func rgb(_ color: [Double]?) -> [Double]? {
        guard let color else { return nil }
        return (color.count == 1 ? [color[0], color[0], color[0]] : color).map { ($0 * 255).rounded(.toNearestOrEven) }
    }

    func test_exportThenImportKeepsTheMeaningOfEveryAnnotation() throws {
        let source = try marked()
        let xml = try PdfXfdf.write(try PdfFdf.export(source, "doc.pdf"))
        let read = try PdfXfdf.read(xml)
        XCTAssertEqual(read.fileName, "doc.pdf")
        XCTAssertEqual(read.annotations.count, PdfAnnotations.readAll(source).filter { $0.type != .popup }.count)

        let target = try AnnotationFixtures.blank(2)
        let result = try PdfFdf.import(target, read)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.withoutAppearance, 0)

        var before: [String: PdfAnnotation] = [:]
        for a in PdfAnnotations.readAll(source) { before[a.name ?? ""] = a }
        for after in PdfAnnotations.readAll(try AnnotationFixtures.reopen(target)) {
            let was = try XCTUnwrap(before[after.name ?? ""])
            XCTAssertEqual(after.subtype, was.subtype)
            XCTAssertEqual(after.rect, was.rect)
            XCTAssertEqual(after.contents, was.contents)
            XCTAssertEqual(after.title, was.title)
            XCTAssertEqual(after.subject, was.subject)
            XCTAssertEqual(after.modified, was.modified)
            XCTAssertEqual(rgb(after.color), rgb(was.color))
            XCTAssertEqual(rgb(after.interiorColor), rgb(was.interiorColor))
            XCTAssertEqual(after.opacity, was.opacity)
            XCTAssertEqual(after.quadPoints, was.quadPoints)
            XCTAssertEqual(after.vertices, was.vertices)
            XCTAssertEqual(after.line, was.line)
            XCTAssertEqual(after.inkList, was.inkList)
            XCTAssertEqual(after.startEnding, was.startEnding)
            XCTAssertEqual(after.endEnding, was.endEnding)
            XCTAssertEqual(after.border.style, was.border.style)
            XCTAssertEqual(after.border.dash, was.border.dash)
            XCTAssertEqual(after.cloud, was.cloud)
            XCTAssertEqual(after.flags, was.flags)
            XCTAssertEqual(after.iconName, was.iconName)
            XCTAssertEqual(after.defaultAppearance, was.defaultAppearance)
            XCTAssertEqual(after.alignment, was.alignment)
            XCTAssertTrue(after.hasAppearance)
        }
        let thread = try XCTUnwrap(PdfComments.list(target).first { $0.text == "şiir & <tag>" })
        XCTAssertEqual(thread.replies.count, 1)
        XCTAssertEqual(thread.replies.first?.contents, "yanıt")
    }

    func test_aTurkishStampNameSurvivesAnXfdfRoundTrip() throws {
        let source = try AnnotationFixtures.blank(1)
        try PdfAnnotationWriter(source, try AnnotationFixtures.ArialSource()).addStamp(source.pages[0], PdfRect(100, 600, 360, 660), "ŞİFRELİ GİZLİ")
        let xml = try PdfXfdf.write(try PdfFdf.export(source, "doc.pdf"))
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).contains("icon=\"ŞİFRELİ GİZLİ\""))
        let target = try AnnotationFixtures.blank(1)
        try PdfFdf.import(target, try PdfXfdf.read(xml), try AnnotationFixtures.ArialSource())
        XCTAssertEqual(PdfAnnotations.readAll(try AnnotationFixtures.reopen(target)).first?.iconName, "ŞİFRELİ GİZLİ")
    }

    func test_readsAnXfdfAsAcrobatWritesIt() throws {
        let xml = #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
              <f href="C:\docs\a.pdf"/>
              <fields>
                <field name="person"><field name="name"><value>Ayşe</value></field><field name="langs"><value>tr</value><value>en</value></field></field>
              </fields>
              <annots>
                <highlight color="#FFFF00" flags="print" name="h1" page="0" rect="10,20,110,34" title="Ali" subject="Highlight"
                           date="D:20260301090000+00'00'" coords="10,34,110,34,10,20,110,20" opacity="0.5">
                  <contents>nice</contents>
                  <popup flags="print,nozoom,norotate" open="no" page="0" rect="120,20,220,100"/>
                </highlight>
                <freetext page="1" rect="50,50,250,100" name="f1" justification="2" flags="print">
                  <contents>text &amp; more</contents>
                  <defaultappearance>/Helv 14 Tf 1 0 0 rg</defaultappearance>
                  <defaultstyle>font: Helvetica 14pt</defaultstyle>
                  <contents-richtext><body xmlns="http://www.w3.org/1999/xhtml"><p><span style="font-weight:bold">text</span> &amp; more</p></body></contents-richtext>
                </freetext>
                <unheardof page="0"/>
                <square page="0" rect="5,5,25,25" name="s1" style="cloudy" intensity="1" interior-color="#00FF00" color="#0000FF" width="2"/>
                <ink page="0" rect="0,0,40,40" name="i1"><inklist><gesture>1,2;3,4;5,6</gesture><gesture>7,8;9,10</gesture></inklist></ink>
              </annots>
            </xfdf>
            """#
        let fdf = try PdfXfdf.read(xml)
        XCTAssertEqual(fdf.fileName, #"C:\docs\a.pdf"#)
        let flat = fdf.flatFields()
        XCTAssertEqual(flat.map { $0.key }, ["person.name", "person.langs"])
        XCTAssertEqual(PdfText.decode(try XCTUnwrap(flat[0].value as? PdfString).bytes), "Ayşe")
        XCTAssertEqual((flat[1].value as? PdfArray)?.items.count, 2)
        XCTAssertEqual(fdf.annotations.count, 4)

        let document = try AnnotationFixtures.blank(2)
        let result = try PdfFdf.import(document, fdf)
        XCTAssertEqual(result, FdfImportResult(imported: 5, skipped: 0, withoutAppearance: 0))
        let onFirst = PdfAnnotations.read(document, document.pages[0])
        let highlight = try XCTUnwrap(onFirst.first { $0.type == .highlight })
        XCTAssertEqual(highlight.contents, "nice")
        XCTAssertEqual(highlight.opacity, 0.5)
        XCTAssertEqual(highlight.color, [1, 1, 0])
        XCTAssertEqual(highlight.flags, .print)
        XCTAssertNotNil(highlight.popup)
        let popup = try XCTUnwrap(onFirst.first { $0.type == .popup })
        XCTAssertEqual(popup.rect, PdfRect(120, 20, 220, 100))
        let square = try XCTUnwrap(onFirst.first { $0.type == .square })
        XCTAssertEqual(square.cloud, 1)
        XCTAssertEqual(square.border.width, 2)
        let ink = try XCTUnwrap(onFirst.first { $0.type == .ink })
        XCTAssertEqual(Array(ink.inkList[0].dropFirst(4)), [5, 6])
        let texts = PdfAnnotations.read(document, document.pages[1])
        XCTAssertEqual(texts.count, 1)
        let text = texts[0]
        XCTAssertEqual(text.alignment, 2)
        XCTAssertTrue((text.richText ?? "").contains("<span style=\"font-weight:bold\">text</span>"))
        XCTAssertEqual(PdfRichText.toPlain(text.richText ?? ""), "text & more")
        try AnnotationFixtures.reopen(document)
    }

    func test_textWithMarkupCharactersAndNewlinesSurvives() throws {
        let document = try AnnotationFixtures.blank(1)
        let tricky = "a < b && c > d \"quoted\" 'single'\nsecond line\ttab"
        try PdfAnnotationWriter(document).addNote(document.pages[0], PdfRect(10, 10, 30, 30), AnnotationInfo(author: "A", contents: tricky))
        let target = try AnnotationFixtures.blank(1)
        try PdfFdf.import(target, try PdfXfdf.read(try PdfXfdf.write(try PdfFdf.export(document))))
        XCTAssertEqual(PdfAnnotations.read(target, target.pages[0]).first?.contents, tricky)
    }

    func test_coloursBeyondTheRangeClampToItsEnds() throws {
        let huge = "-1" + String(repeating: "0", count: 200)
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Subtype /Square /Rect [0 0 5 5] /C [\(huge) 0 0 \(huge)]>>") }, pageEntries: "/Annots [20 0 R]")
        let xml = Latin1.string(try PdfXfdf.write(try PdfFdf.export(document)))
        XCTAssertTrue(xml.contains("color=\"#FFFFFF\""))
    }

    func test_anElementWithManyAttributesIsReadQuickly() throws {
        var xml = "<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots><text page=\"0\" rect=\"1,1,2,2\" name=\"a\""
        for i in 0..<100_000 { xml += " a\(i)=\"\"" }
        xml += "/></annots></xfdf>"
        XCTAssertEqual(try PdfXfdf.read(xml).annotations.count, 1)
    }

    func test_fieldValuesRoundTrip() throws {
        let fdf = FdfFile()
        fdf.fields.append(FdfField("a", PdfText.toObject("bir"), []))
        fdf.fields.append(FdfField("g", nil, [FdfField("b", PdfName("Yes"), []), FdfField("c", PdfArray([PdfText.toObject("x"), PdfText.toObject("y")]), [])]))
        let read = try PdfXfdf.read(try PdfXfdf.write(fdf))
        let flat = read.flatFields()
        XCTAssertEqual(flat.map { $0.key }, ["a", "g.b", "g.c"])
        XCTAssertEqual(PdfText.decode(try XCTUnwrap(flat[1].value as? PdfString).bytes), "Yes")
        XCTAssertEqual((flat[2].value as? PdfArray)?.items.count, 2)
    }

    func test_outputIsWellFormedUtf8WithNamespace() throws {
        let bytes = try PdfXfdf.write(try PdfFdf.export(try marked()))
        let xml = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(xml.hasPrefix("<?xml"))
        XCTAssertTrue(xml.contains("xmlns=\"http://ns.adobe.com/xfdf/\""))
        XCTAssertEqual(bytes[0], UInt8(ascii: "<"))
        XCTAssertTrue(xml.contains("şiir"))
    }

    func test_badXmlIsDamagedNotACrash() {
        let cases = [
            "not xml at all",
            "<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots>",
            "<other/>",
            "<!DOCTYPE xfdf [<!ENTITY x SYSTEM \"file:///c:/windows/win.ini\">]><xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><fields><field name=\"a\"><value>&x;</value></field></fields></xfdf>",
        ]
        for xml in cases {
            XCTAssertThrowsError(try PdfXfdf.read(xml), xml) { XCTAssertEqual(($0 as? PdfReadException)?.problem, .damaged) }
        }
    }

    // Not in the C#: there the cast of the parent's /NM to a string raises InvalidCastException.
    func test_aReplyWhoseParentNameIsNotAStringIsWritten() throws {
        let file = TestPdf.latin("%FDF-1.2\n1 0 obj\n<</FDF<</Annots [2 0 R 3 0 R]>>>>\nendobj\n2 0 obj\n<</Subtype /Text /Page 0 /NM 5>>\nendobj\n3 0 obj\n<</Subtype /Text /Page 0 /IRT 2 0 R>>\nendobj\ntrailer\n<</Root 1 0 R>>\n")
        let xml = String(decoding: try PdfXfdf.write(try PdfFdf.read(file)), as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<text ").count - 1, 2)
        XCTAssertFalse(xml.contains("inreplyto"))
    }

    func test_valuesThatAreNotNumbersDoNotBreakImport() throws {
        let fdf = try PdfXfdf.read("<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots><square page=\"0\" rect=\"a,b,c,d\" color=\"red\" width=\"x\" coords=\"1,2\"/><square page=\"0\" rect=\"1,1,2,2\" opacity=\"NaN\"/><square page=\"-4\" rect=\"1,1,9,9\"/></annots></xfdf>")
        let document = try AnnotationFixtures.blank(1)
        let result = try PdfFdf.import(document, fdf)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
    }
}
