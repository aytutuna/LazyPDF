import Foundation
import LazyPDFKit
@testable import LazyPDFApp

// Forms for the tests of the Forms tool, made with the engine's own authoring; follows windows/LazyPDF.App.Tests/Tools/forms/FormPdfs.cs.

enum FormPdfs {
    static let fonts = FakeFonts()

    /// A text file page with text "name" (required), "code" (at most 4 characters), check box "agree", radio group "plan",
    /// combo "city" and multi-select list "langs".
    static func standard() throws -> [UInt8] {
        let document = try PdfDocument.open(Pdfs.text(2))
        let form = PdfForm.read(document, fonts)
        try form.addField(FieldSpec(.text, "name", 0, PdfRect(60, 640, 300, 660), flags: .required))
        try form.addField(FieldSpec(.text, "code", 0, PdfRect(60, 610, 160, 630), maxLength: 4))
        try form.addField(FieldSpec(.checkBox, "agree", 0, PdfRect(60, 580, 74, 594)))
        let plan = try form.addField(FieldSpec(.radio, "plan", 0, PdfRect(60, 550, 74, 564)))
        _ = try form.addWidget(plan, 0, PdfRect(120, 550, 134, 564))
        try form.addField(FieldSpec(.comboBox, "city", 0, PdfRect(60, 510, 200, 528), options: [FieldOption("Ankara"), FieldOption("IZ", "Izmir")]))
        try form.addField(FieldSpec(.listBox, "langs", 0, PdfRect(60, 420, 200, 490), 
                                    options: [FieldOption("Turkish"), FieldOption("English"), FieldOption("German")], flags: .multiSelect))
        return try document.saveRewrite(PdfSaveOptions())
    }

    /// The standard form on a page turned a quarter.
    static func turned() throws -> [UInt8] {
        let document = try PdfDocument.open(standard())
        document.pages[0].dictionary["Rotate"] = PdfNumber(90)
        return try document.saveRewrite(PdfSaveOptions())
    }

    /// A form that has fields and also XFA data.
    static func staticXfa() throws -> [UInt8] {
        let document = try PdfDocument.open(standard())
        let form = PdfForm.read(document, fonts)
        form.acroForm!["XFA"] = PdfArray([PdfText.toObject("template"), PdfText.toObject("<xdp/>")])
        return try document.saveRewrite(PdfSaveOptions())
    }

    /// A form that exists only as XFA.
    static func dynamicXfa() -> [UInt8] {
        Array(("%PDF-1.7\n1 0 obj\n<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 4 0 R]>>>>\nendobj\n"
            + "2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n"
            + "3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 200 200]>>\nendobj\n"
            + "4 0 obj\n<</Length 6>>\nstream\n<xdp/>\nendstream\nendobj\n"
            + "trailer\n<</Root 1 0 R /Size 5>>\n%%EOF\n").utf8)
    }

    @MainActor
    static func tab(_ pdf: [UInt8]? = nil) throws -> DocumentTab {
        let bytes = try pdf ?? standard()
        return DocumentTab(session: try PdfEditSession.open(bytes), renderer: FakeRenderer(), url: nil, title: "form.pdf")
    }

    @MainActor
    static func read(_ tab: DocumentTab) -> PdfForm {
        PdfForm.read(tab.document, fonts)
    }
}
