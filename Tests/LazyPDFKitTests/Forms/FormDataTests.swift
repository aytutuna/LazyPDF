import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormDataTests.cs: the same cases. The PdfPig page counts of OnePdfPerCsvRow have no
// Swift twin, and BulkRowsCanBeFlattenedAndHoldTurkishText reads the text back with the Text layer instead of PdfPig. The
// font source is the synthetic font (A, B, space, ğ, İ and À).

final class FormDataTests: XCTestCase {
    private func open(_ fonts: FontSource? = nil) throws -> PdfForm { PdfForm.read(try FormFixtures.open(), fonts) }

    private func values(_ fdf: FdfFile) -> [String: String] {
        var result: [String: String] = [:]
        for pair in fdf.flatFields() {
            switch fdf.resolve(pair.value) {
            case let s as PdfString: result[pair.key] = PdfText.decode(s.bytes)
            case let n as PdfName: result[pair.key] = n.value
            case let a as PdfArray: result[pair.key] = a.items.map { PdfText.decode(($0 as? PdfString)?.bytes ?? []) }.joined(separator: "|")
            default: result[pair.key] = "?"
            }
        }
        return result
    }

    func test_fdfCarriesValuesButNotButtonsOrSignatures() throws {
        let form = try open()
        try form.setValues([("name", "Ada"), ("agree", "Yes"), ("choice", "b"), ("city", "Izmir"), ("langs", "English; German")])

        let fdf = try PdfFdf.read(try PdfFdf.write(form.exportFdf("form.pdf")))

        XCTAssertEqual(fdf.fileName, "form.pdf")
        let found = values(fdf)
        XCTAssertEqual(found["name"], "Ada")
        XCTAssertEqual(found["agree"], "Yes")
        XCTAssertEqual(found["choice"], "b")
        XCTAssertEqual(found["city"], "IZ")
        XCTAssertEqual(found["langs"], "English|German")
        XCTAssertEqual(found["bio"], "")
        XCTAssertNil(found["sig"])
        XCTAssertEqual(found.count, 8)
    }

    func test_fdfOfNestedNamesIsNested() throws {
        let form = PdfForm.read(try AnnotationFixtures.blank())
        try form.addField(FieldSpec(.text, "person.first", 0, PdfRect(50, 700, 250, 720), value: "Ada"))

        let fdf = form.exportFdf()

        XCTAssertEqual(fdf.fields.count, 1)
        let person = try XCTUnwrap(fdf.fields.first)
        XCTAssertEqual(person.name, "person")
        XCTAssertEqual(person.kids.count, 1)
        XCTAssertEqual(person.kids.first?.name, "first")
        XCTAssertEqual(values(try PdfFdf.read(try PdfFdf.write(fdf)))["person.first"], "Ada")
    }

    func test_fdfAndXfdfFillAnotherCopyOfTheForm() throws {
        let source = try open()
        try source.setValues([("name", "Grace"), ("agree", "Yes"), ("choice", "a"), ("code", "42"), ("langs", "Greek; Latin")])
        let fdf = source.exportFdf()

        for carried in [try PdfFdf.read(try PdfFdf.write(fdf)), try PdfXfdf.read(try PdfXfdf.write(fdf))] {
            let target = try open()
            let result = try target.importFdf(carried)

            XCTAssertTrue(result.unknownFields.isEmpty)
            XCTAssertEqual(target.find("name")?.value, "Grace")
            XCTAssertTrue(try XCTUnwrap(target.find("agree")).isChecked)
            XCTAssertEqual(target.find("choice")?.value, "a")
            XCTAssertEqual(target.find("code")?.value, "42")
            XCTAssertEqual(target.find("langs")?.selected, ["Greek", "Latin"])
            XCTAssertEqual(try FormFixtures.drawn(target.document, try XCTUnwrap(target.find("name")).widgets[0]), "Grace")
        }
    }

    func test_importReportsNamesTheFormDoesNotHave() throws {
        let fdf = FdfFile()
        fdf.fields.append(FdfField("name", PdfText.toObject("x"), []))
        fdf.fields.append(FdfField("ghost", PdfText.toObject("y"), []))

        let result = try open().importFdf(fdf)

        XCTAssertEqual(result.unknownFields, ["ghost"])
        XCTAssertEqual(result.filled, 1)
    }

    func test_turkishValuesTravelThroughFdf() throws {
        let fdf = FdfFile()
        fdf.fields.append(FdfField("name", PdfText.toObject("AğB İA"), []))
        let target = try open(try AnnotationFixtures.ArialSource())

        try target.importFdf(try PdfFdf.read(try PdfFdf.write(fdf)))

        XCTAssertEqual(target.find("name")?.value, "AğB İA")
        XCTAssertEqual(try FormFixtures.drawn(target.document, try XCTUnwrap(target.find("name")).widgets[0]), "AğB İA")
    }

    func test_csvExportIsAHeaderAndARow() throws {
        let form = try open()
        try form.setValues([("name", "Lovelace, Ada"), ("bio", "line one\nline \"two\""), ("langs", "English; German")])

        let csv = form.exportCsv()

        let rows = FormCsv.read(csv)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["name", "bio", "agree", "choice", "city", "langs", "code", "secret"])
        XCTAssertEqual(rows[1][0], "Lovelace, Ada")
        XCTAssertEqual(rows[1][1], "line one\nline \"two\"")
        XCTAssertEqual(rows[1][2], "Off")
        XCTAssertEqual(rows[1][5], "English; German")
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func test_csvReadingFollowsRfc4180AndSpreadsheetHabits() {
        let rows = FormCsv.read("\u{FEFF}a;b;c\r\n1;\"x;y\";\r\n\r\n\"two\nlines\";\"say \"\"hi\"\"\";3\r\n")

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[1], ["1", "x;y", ""])
        XCTAssertEqual(rows[2], ["two\nlines", "say \"hi\"", "3"])
        XCTAssertEqual(FormCsv.read("a\tb\n1\t2"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(FormCsv.read("only"), [["only"]])
        XCTAssertTrue(FormCsv.read("").isEmpty)
    }

    func test_onePdfPerCsvRow() throws {
        let bytes = FormFixtures.standard()
        let bulk = try BulkFill.create(bytes, "name,agree,city,nothing\r\nAda,yes,Izmir,x\r\n\"Lovelace, A\",no,Bursa,y\r\n")

        XCTAssertEqual(bulk.rows, 2)
        XCTAssertEqual(bulk.unmatchedColumns, ["nothing"])

        let first = try PdfDocument.open(try bulk.fill(0))
        let second = try PdfDocument.open(try bulk.fill(1))
        let a = PdfForm.read(first)
        let b = PdfForm.read(second)
        XCTAssertEqual(a.find("name")?.value, "Ada")
        XCTAssertTrue(try XCTUnwrap(a.find("agree")).isChecked)
        XCTAssertEqual(a.find("city")?.value, "IZ")
        XCTAssertEqual(b.find("name")?.value, "Lovelace, A")
        XCTAssertFalse(try XCTUnwrap(b.find("agree")).isChecked)
        XCTAssertEqual(try FormFixtures.drawn(second, try XCTUnwrap(b.find("name")).widgets[0]), "Lovelace, A")
        XCTAssertTrue(first.repairs.isEmpty)
        XCTAssertNil(PdfForm.read(try PdfDocument.open(bytes)).find("name")?.value)
    }

    func test_bulkRowsCanBeFlattenedAndHoldTurkishText() throws {
        let bulk = try BulkFill.create(FormFixtures.standard(), "name;city\nAİB ğA;Bursa\n", try AnnotationFixtures.ArialSource())

        let document = try PdfDocument.open(try bulk.fill(0, flatten: true))

        XCTAssertNil(document.dict(document.catalog, "AcroForm"))
        XCTAssertTrue(TextPage.create(document, document.pages[0]).text.contains("AİB ğA"))
    }

    func test_bulkFillRefusesDynamicXfa() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 12 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")

        assertReadFails(try BulkFill.create(pdf.finish(), "a\n1\n"))
    }

    func test_aFieldNameOfEndlessPartsExportsAtABoundedDepth() throws {
        let name = String(repeating: "a.", count: 100_000) + "z"
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R]>>")
        pdf.obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T (\(name)) /V (x) /Rect [0 0 100 20] /P 3 0 R>>")
        let form = PdfForm.read(try PdfDocument.open(pdf.finish()))

        let fdf = try PdfFdf.read(try PdfFdf.write(form.exportFdf()))

        XCTAssertEqual(fdf.flatFields().map { $0.key }, [name])
    }
}
