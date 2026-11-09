import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/forms/FormDataTests.cs: the four data formats of the Forms tool against a form read by
// the engine.

final class FormDataTests: XCTestCase {
    private let fonts = FormPdfs.fonts

    private func empty() throws -> PdfForm {
        PdfForm.read(try PdfDocument.open(FormPdfs.standard()), fonts)
    }

    private func filled() throws -> PdfForm {
        let form = try empty()
        _ = try form.setValues([("name", "Ada"), ("agree", "Yes"), ("city", "IZ")])
        _ = try form.setChoices("langs", ["Turkish", "German"])
        return PdfForm.read(form.document, fonts)
    }

    func test_theFormatComesFromTheExtension() {
        XCTAssertEqual(FormData.format(of: "a.fdf"), .fdf)
        XCTAssertEqual(FormData.format(of: "a.XFDF"), .xfdf)
        XCTAssertEqual(FormData.format(of: "b.csv"), .csv)
        XCTAssertEqual(FormData.format(of: "c.json"), .json)
    }

    func test_anOtherExtensionHasNoFormat() {
        XCTAssertNil(FormData.format(of: "notes.txt"))
    }

    func test_whatIsExportedFillsAnEmptyCopy() throws {
        for format in DataFormat.allCases {
            let data = try FormData.export(try filled(), format, fileName: "form.pdf")
            let target = try empty()

            let (result, rows) = try FormData.import(target, format, data)
            let after = PdfForm.read(target.document, fonts)

            XCTAssertEqual(rows, 1, "\(format)")
            XCTAssertTrue(result.unknownFields.isEmpty, "\(format)")
            XCTAssertEqual(after.find("name")?.value, "Ada", "\(format)")
            XCTAssertEqual(after.find("agree")?.value, "Yes", "\(format)")
            XCTAssertEqual(after.find("city")?.value, "IZ", "\(format)")
            XCTAssertEqual(after.find("langs")?.selected, ["Turkish", "German"], "\(format)")
        }
    }

    func test_aCsvFileStartsWithAByteOrderMarkForExcel() throws {
        let data = try FormData.export(try filled(), .csv, fileName: "form.pdf")

        XCTAssertEqual(Array(data[0..<3]), [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(String(decoding: data.dropFirst(3), as: UTF8.self).hasPrefix("name,"))
    }

    func test_aCsvWithSeveralRowsFillsFromTheFirstAndSaysSo() throws {
        let form = try empty()
        let csv = "name;code\r\nAda;1234\r\nGrace;5678\r\n"

        let (result, rows) = try FormData.import(form, .csv, Array(csv.utf8))

        XCTAssertEqual(rows, 2)
        XCTAssertEqual(result.filled, 2)
        XCTAssertEqual(PdfForm.read(form.document, fonts).find("name")?.value, "Ada")
    }

    func test_aCsvSavedInTheAnsiCodePageStillReadsItsTurkishLetters() throws {
        let form = try empty()
        let data = try XCTUnwrap("name;code\r\n\u{00C7}elik;12\r\n".data(using: .windowsCP1254))

        _ = try FormData.import(form, .csv, [UInt8](data))

        XCTAssertEqual(PdfForm.read(form.document, fonts).find("name")?.value, "\u{00C7}elik")
    }

    func test_aCsvCellInQuotesKeepsItsSeparatorsAndLineBreaks() {
        let table = FormData.parseCsv("a,b\n\"x, \"\"y\"\"\nz\",2\n")

        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table[1][0], "x, \"y\"\nz")
        XCTAssertEqual(table[1][1], "2")
    }

    func test_aColumnNoFieldHasIsReportedNotFatal() throws {
        let (result, _) = try FormData.import(try empty(), .csv, Array("name,nothing\nAda,x\n".utf8))

        XCTAssertEqual(result.unknownFields, ["nothing"])
        XCTAssertEqual(result.filled, 1)
    }

    func test_aCsvWithoutADataRowIsRefused() throws {
        XCTAssertThrowsError(try FormData.import(try empty(), .csv, Array("name,code\n".utf8))) {
            XCTAssertTrue($0 is FormDataException, "\($0)")
        }
    }

    func test_jsonTakesNumbersBooleansAndArrays() throws {
        let form = try empty()
        let json = #"{ "name": "Grace", "code": 42, "agree": true, "langs": ["English", "German"] }"#

        _ = try FormData.import(form, .json, Array(json.utf8))
        let after = PdfForm.read(form.document, fonts)

        XCTAssertEqual(after.find("name")?.value, "Grace")
        XCTAssertEqual(after.find("code")?.value, "42")
        XCTAssertEqual(after.find("agree")?.isChecked, true)
        XCTAssertEqual(after.find("langs")?.selected, ["English", "German"])
    }

    func test_jsonThatIsNotAnObjectIsRefused() throws {
        XCTAssertThrowsError(try FormData.import(try empty(), .json, Array("[1, 2]".utf8))) {
            XCTAssertTrue($0 is FormDataException, "\($0)")
        }
    }

    func test_brokenFdfIsRefusedAsDamaged() throws {
        XCTAssertThrowsError(try FormData.import(try empty(), .fdf, Array("not an fdf".utf8))) {
            XCTAssertTrue($0 is PdfReadException, "\($0)")
        }
    }

    func test_jsonLeavesOutButtonsAndSignatures() throws {
        let document = try PdfDocument.open(FormPdfs.standard())
        let form = PdfForm.read(document, fonts)
        try form.addField(FieldSpec(.pushButton, "send", 0, PdfRect(300, 640, 400, 664), caption: "Send"))
        try form.addField(FieldSpec(.signature, "sign", 0, PdfRect(300, 560, 500, 600)))

        let data = try FormData.export(PdfForm.read(document, fonts), .json, fileName: "form.pdf")
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("\"send\""))
        XCTAssertFalse(text.contains("\"sign\""))
        XCTAssertTrue(text.contains("\"name\""))
    }

    func test_jsonKeepsTheOrderOfTheFileAndEscapesWhatNeedsIt() throws {
        let form = try empty()
        _ = try form.setValue("name", "Say \"hi\"\n\u{00E7}")

        let data = try FormData.export(PdfForm.read(form.document, fonts), .json, fileName: "form.pdf")
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"name\": \"Say \\\"hi\\\"\\n\u{00E7}\""))
        let target = try empty()
        _ = try FormData.import(target, .json, data)
        XCTAssertEqual(PdfForm.read(target.document, fonts).find("name")?.value, "Say \"hi\"\n\u{00E7}")
    }
}
