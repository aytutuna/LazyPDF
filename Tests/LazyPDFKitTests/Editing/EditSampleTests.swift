import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/EditSampleTests.cs: with LAZYPDF_EDIT_OUT set to a folder, writes a page
// before and after a run of edits, to be drawn and looked at. The C# reads "Yıllık" back with PdfPig, which has no twin;
// here the engine's own text reading checks it.

final class EditSampleTests: XCTestCase {
    func test_aBusyPageSurvivesARunOfEdits() throws {
        let jpeg = try EditPaint.jpeg()
        let content =
            "0.9 0.9 1 rg 40 560 520 200 re f\n" +
            "BT /F2 24 Tf 0 0 0.5 rg 60 720 Td (Quarterly report) Tj ET\n" +
            "BT /F1 12 Tf 0 g 14 TL 60 690 Td (The quick brown fox jumps over) Tj T* (the lazy dog and keeps running) Tj T* (until the end of the day) Tj ET\n" +
            "q 120 0 0 90 60 450 cm /Im1 Do Q\n" +
            "q 90 0 0 90 220 450 cm /Im2 Do Q\n" +
            "1 0 0 rg 0 0 1 RG 3 w 380 450 120 90 re B\n" +
            "BT /F1 10 Tf 0 g 60 400 Td (footnote one) Tj ET\n"
        let session = try PdfEditSession.open(EditKit.file(content, more: { pdf in
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
            pdf.stream(8, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255, 255, 0])
        }, resources: "/Font <</F1 5 0 R /F2 6 0 R>> /XObject <</Im1 7 0 R /Im2 8 0 R>>"))
        let folder = ProcessInfo.processInfo.environment["LAZYPDF_EDIT_OUT"]
        if let folder {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try Data(session.current).write(to: URL(fileURLWithPath: folder).appendingPathComponent("before.pdf"))
        }

        let fonts = EditArialSource()
        var editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.replaceText(try EditKit.find(session, "Quarterly"), "Yıllık").done)
        editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.setTextStyle([try EditKit.find(session, "brown fox")], TextStyleChange(bold: true, color: RgbColor(180, 0, 0))).done)
        editor = try PageEditor(session, 0, fonts)
        let paragraph = try XCTUnwrap(try editor.objects.compactMap { $0 as? TextObject }.first { $0.text.hasPrefix("The quick") })
        XCTAssertTrue(try editor.replaceParagraph(paragraph, "Çalışma raporu: the quick brown fox jumps over the lazy dog and keeps running until the end of the day, then rests").done)
        editor = try PageEditor(session, 0, fonts)
        let images = try editor.objects.compactMap { $0 as? ImageObject }
        XCTAssertTrue(try editor.rotate([images[0]], 20).done)
        editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.crop(try XCTUnwrap(try editor.objects.compactMap { $0 as? ImageObject }.last), PdfRect(220, 450, 280, 520)).done)
        editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.setPathStyle(Array(try editor.objects.compactMap { $0 as? PathObject }.dropFirst()), fill: RgbColor(0, 150, 0), lineWidth: 6).done)
        editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.addEllipse(PdfRect(380, 330, 500, 400), ShapeStyle(stroke: RgbColor(0, 0, 0), fill: RgbColor(255, 220, 0), width: 2)).done)
        editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.addTextBox(PdfRect(60, 280, 300, 380), "Yeni metin kutusu: ğüşiöç wraps inside its box and stays upright.",
                                            TextBoxStyle(family: "Arial", size: 12, color: RgbColor(0, 100, 0))).done)
        editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.move(try editor.objects.filter { ($0 as? TextObject)?.text.hasPrefix("footnote") == true }, 240, 0).done)
        if let folder { try Data(session.current).write(to: URL(fileURLWithPath: folder).appendingPathComponent("after.pdf")) }

        XCTAssertTrue(try EditKit.text(session).contains("Yıllık"))
        while session.canUndo { _ = try session.undo() }
        XCTAssertEqual(EditKit.latin(session).count, content.count)
    }
}
