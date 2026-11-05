import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormFixtures.cs: the same file and helpers.

enum FormFixtures {
    private static let helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"

    /// A one-page form (600 by 800): text "name" and multiline "bio", check box "agree", radio group "choice" (buttons a and
    /// b), combo "city", multi-select list "langs", comb "code", password "secret", signature "sig".
    static func standard(_ acroEntries: String = "") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 10 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [20 0 R 21 0 R 22 0 R 24 0 R 25 0 R 26 0 R 27 0 R 28 0 R 29 0 R 33 0 R]>>")
        pdf.obj(10, "<</Fields [20 0 R 21 0 R 22 0 R 23 0 R 26 0 R 27 0 R 28 0 R 29 0 R 33 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 11 0 R>>>> \(acroEntries)>>")
        pdf.obj(11, helvetica)
        pdf.obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [50 700 250 720] /F 4 /P 3 0 R /MK <</BC [0] /BG [1 1 0.8]>> /DA (/Helv 12 Tf 0 0 1 rg)>>")
        pdf.obj(21, "<</Type /Annot /Subtype /Widget /FT /Tx /Ff 4096 /T (bio) /Rect [50 600 250 680] /F 4 /P 3 0 R /MK <</BC [0]>>>>")
        pdf.obj(22, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /Rect [50 560 64 574] /F 4 /P 3 0 R /AS /Off /MK <</BC [0] /CA (4)>> /AP <</N <</Yes 30 0 R /Off 31 0 R>>>>>>")
        pdf.obj(23, "<</FT /Btn /Ff 49152 /T (choice) /V /Off /Kids [24 0 R 25 0 R]>>")
        pdf.obj(24, "<</Type /Annot /Subtype /Widget /Parent 23 0 R /Rect [50 520 64 534] /F 4 /P 3 0 R /AS /Off /MK <</BC [0] /CA (l)>> /AP <</N <</a 30 0 R /Off 31 0 R>>>>>>")
        pdf.obj(25, "<</Type /Annot /Subtype /Widget /Parent 23 0 R /Rect [100 520 114 534] /F 4 /P 3 0 R /AS /Off /MK <</BC [0] /CA (l)>> /AP <</N <</b 30 0 R /Off 31 0 R>>>>>>")
        pdf.obj(26, "<</Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (city) /Rect [50 480 200 498] /F 4 /P 3 0 R /Opt [(Ankara) [(IZ) (Izmir)] (Bursa)] /MK <</BC [0]>>>>")
        pdf.obj(27, "<</Type /Annot /Subtype /Widget /FT /Ch /Ff 2097152 /T (langs) /Rect [50 380 200 460] /F 4 /P 3 0 R /Opt [(Turkish) (English) (German) (French) (Dutch) (Greek) (Latin)] /MK <</BC [0]>>>>")
        pdf.obj(28, "<</Type /Annot /Subtype /Widget /FT /Tx /Ff 16777216 /MaxLen 6 /T (code) /Rect [50 340 170 360] /F 4 /P 3 0 R /MK <</BC [0]>>>>")
        pdf.obj(29, "<</Type /Annot /Subtype /Widget /FT /Tx /Ff 8192 /T (secret) /Rect [50 300 200 320] /F 4 /P 3 0 R /MK <</BC [0]>>>>")
        pdf.stream(30, "/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "0 0 14 14 re f")
        pdf.stream(31, "/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "")
        pdf.obj(33, "<</Type /Annot /Subtype /Widget /FT /Sig /T (sig) /Rect [300 300 450 340] /F 4 /P 3 0 R>>")
        return pdf.finish()
    }

    static func open(_ acroEntries: String = "") throws -> PdfDocument {
        try PdfDocument.open(standard(acroEntries))
    }

    /// The words drawn by a widget's normal appearance, in order.
    static func drawn(_ document: PdfDocument, _ widget: FormWidget, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let ap = document.dict(widget.dictionary, "AP")
        var normal = document.resolve(ap?["N"])
        if let states = normal as? PdfDictionary {
            normal = document.resolve(states[document.name(widget.dictionary, "AS") ?? "Off"])
        }
        guard let stream = normal as? PdfStream else {
            XCTFail("The widget has no normal appearance.", file: file, line: line)
            throw MissingAppearance()
        }
        let recorder = TextRecorder()
        ContentInterpreter(document).run(stream, recorder)
        return recorder.text
    }

    private final class TextRecorder: ContentVisitor {
        var text = ""

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            text += glyph.unicode ?? ""
        }
    }
}

extension XCTestCase {
    func assertArgumentException<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertTrue(error is ArgumentException, "\(error)", file: file, line: line)
        }
    }
}
