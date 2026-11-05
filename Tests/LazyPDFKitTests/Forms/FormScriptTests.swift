import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormScriptTests.cs: the same cases. A [Theory] is one test that loops over its
// cases.

final class FormScriptTests: XCTestCase {
    // Text fields a, b and total on one page; the arguments are the extra keys of each.
    private func build(a: String = "", b: String = "", total: String = "", acro: String = "", catalog: String = "") throws -> PdfForm {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog) /AcroForm <</Fields [10 0 R 11 0 R 12 0 R] /DA (/Helv 10 Tf 0 g) /DR <</Font <</Helv 20 0 R>>>> \(acro)>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R 12 0 R]>>")
        pdf.obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 100 20] /P 3 0 R \(a)>>")
        pdf.obj(11, "<</Type /Annot /Subtype /Widget /FT /Tx /T (b) /Rect [0 40 100 60] /P 3 0 R \(b)>>")
        pdf.obj(12, "<</Type /Annot /Subtype /Widget /FT /Tx /T (total) /Rect [0 80 100 100] /P 3 0 R \(total)>>")
        pdf.obj(20, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        return PdfForm.read(try PdfDocument.open(pdf.finish()))
    }

    private func js(_ event: String, _ source: String) -> String { "/AA <</\(event) <</S /JavaScript /JS (\(source))>>>>" }

    private func call(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> FormCall {
        try XCTUnwrap(FormScriptParser.parse(source)?.first, file: file, line: line)
    }

    func test_builtInCallsAreUnderstood() {
        let sources = [
            "AFNumber_Format(2, 0, 0, 0, \"$\", true);",
            "AFNumber_Format(2,0,0,0,'',true)",
            "// totals\nAFSimple_Calculate(\"SUM\", new Array(\"a\", \"b\"));",
            "AFDate_FormatEx(\"dd/mm/yyyy\"); AFRange_Validate(true, 0, false, 0)",
            "AFSimple_Calculate('AVG', ['a','b'])",
        ]
        for source in sources { XCTAssertNotNil(FormScriptParser.parse(source), source) }
    }

    func test_anythingElseIsLeftAlone() {
        let sources = [
            "event.value = 1;",
            "AFNumber_Format(2, 0, 0, 0, \"$\", true); app.alert(1);",
            "AFNumber_Format(x);",
            "AFNumber_Format(2, 0",
            "AFUnknown_Format(2);",
            "",
        ]
        for source in sources { XCTAssertNil(FormScriptParser.parse(source), source) }
    }

    func test_argumentsKeepTheirTypes() throws {
        let c = try call("AFNumber_Format(2, -1, 3.5, 0, 'A\\'s', false)")

        XCTAssertEqual(c.name, "AFNumber_Format")
        XCTAssertEqual(c.number(0), 2)
        XCTAssertEqual(c.number(1), -1)
        XCTAssertEqual(c.number(2), 3.5)
        XCTAssertEqual(c.text(4), "A's")
        XCTAssertFalse(c.flag(5, true))
    }

    func test_formatsShowTheValueTheWayAcrobatDoes() throws {
        let cases: [(String, String, String)] = [
            ("AFNumber_Format(2, 0, 0, 0, \"\", true)", "1234.5", "1,234.50"),
            ("AFNumber_Format(0, 1, 0, 0, \"\", true)", "1234.5", "1235"),
            ("AFNumber_Format(2, 2, 0, 0, \"\", true)", "1234.5", "1.234,50"),
            ("AFNumber_Format(2, 3, 0, 0, \"\", true)", "1234,5", "1234,50"),
            ("AFNumber_Format(2, 0, 0, 0, \" TL\", false)", "10", "10.00 TL"),
            ("AFNumber_Format(2, 0, 0, 0, \"$\", true)", "-3", "-$3.00"),
            ("AFNumber_Format(2, 0, 2, 0, \"\", true)", "-3", "(3.00)"),
            ("AFPercent_Format(1, 0)", "0.256", "25.6%"),
            ("AFDate_FormatEx(\"dd/mm/yyyy\")", "2024-03-05", "05/03/2024"),
            ("AFDate_FormatEx(\"mmmm d, yyyy\")", "3/5/2024", "March 5, 2024"),
            ("AFDate_Format(2)", "2024-03-05", "03/05/24"),
            ("AFTime_Format(1)", "13:05", "1:05 pm"),
            ("AFTime_FormatEx(\"HH:MM:ss\")", "9:05:07 am", "09:05:07"),
            ("AFSpecial_Format(0)", "34000", "34000"),
            ("AFSpecial_Format(1)", "340001234", "34000-1234"),
            ("AFSpecial_Format(2)", "5551234567", "(555) 123-4567"),
            ("AFSpecial_Format(3)", "123456789", "123-45-6789"),
        ]
        for (source, value, shown) in cases {
            XCTAssertEqual(FormFunctions.format(try call(source), value)?.text, shown, "\(source) \(value)")
        }
    }

    func test_valuesThatDoNotFitTheFormatAreShownAsTheyAre() throws {
        XCTAssertNil(FormFunctions.format(try call("AFNumber_Format(2, 0, 0, 0, \"\", true)"), "abc"))
        XCTAssertNil(FormFunctions.format(try call("AFDate_Format(1)"), "not a date"))
        XCTAssertNil(FormFunctions.format(try call("AFSpecial_Format(0)"), "123"))
        XCTAssertNil(FormFunctions.format(try call("AFNumber_Format(2, 0, 0, 0, \"\", true)"), ""))
        XCTAssertEqual(FormFunctions.format(try call("AFNumber_Format(2, 0, 1, 0, \"\", true)"), "-1")?.color, [1, 0, 0])
    }

    func test_numbersParseWhicheverWayTheyWereWritten() {
        let cases: [(String, Double)] = [
            ("1,234.56", 1234.56), ("1.234,56", 1234.56), ("1234,5", 1234.5), ("$ 12", 12), ("(7.5)", -7.5),
            ("12%", 12), ("1'234.5", 1234.5), ("-.5", -0.5),
        ]
        for (text, expected) in cases { XCTAssertEqual(FormFunctions.parseNumber(text), expected, text) }
    }

    func test_nonNumbersDoNotParse() {
        for text in ["12abc", "", "text"] { XCTAssertNil(FormFunctions.parseNumber(text), text) }
    }

    func test_simpleCalculationsOverNamedFields() throws {
        let cases = [("SUM", "10"), ("AVG", "3.3333333333"), ("PRD", "30"), ("MIN", "2"), ("MAX", "5")]
        let values: [String?] = ["3", "5", "2"]
        for (function, expected) in cases {
            let c = try call("AFSimple_Calculate(\"\(function)\", new Array(\"a\", \"b\", \"c\"))")

            let result = FormFunctions.calculate(c) { name in
                let index = "abc".firstIndex(of: name.first ?? " ").map { "abc".distance(from: "abc".startIndex, to: $0) } ?? -1
                return [values[index]]
            }

            XCTAssertEqual(result, expected, function)
        }
    }

    func test_rangeAndKeystrokeChecksSayWhatIsWrong() throws {
        XCTAssertNil(FormFunctions.check(try call("AFRange_Validate(true, 0, true, 100)"), "50"))
        XCTAssertEqual(FormFunctions.check(try call("AFRange_Validate(true, 0, true, 100)"), "101"), FormText.outOfRange("0", "100"))
        XCTAssertEqual(FormFunctions.check(try call("AFRange_Validate(true, 0, false, 0)"), "-1"), FormText.atLeast("0"))
        XCTAssertEqual(FormFunctions.check(try call("AFRange_Validate(false, 0, true, 9)"), "10"), FormText.atMost("9"))
        XCTAssertEqual(FormFunctions.check(try call("AFNumber_Keystroke(2, 0, 0, 0, \"\", true)"), "x1y"), FormText.badNumber)
        XCTAssertEqual(FormFunctions.check(try call("AFDate_KeystrokeEx(\"dd/mm/yyyy\")"), "soon"), FormText.badDate)
        XCTAssertEqual(FormFunctions.check(try call("AFSpecial_KeystrokeEx(\"AA-999\")"), "A1-234"), FormText.badFormat)
        XCTAssertNil(FormFunctions.check(try call("AFSpecial_KeystrokeEx(\"AA-999\")"), "AB-234"))
    }

    func test_formatScriptChangesWhatTheAppearanceShowsNotTheValue() throws {
        let form = try build(a: js("F", "AFNumber_Format(2, 0, 3, 0, \\\"\\\", true);"))

        try form.setValue("a", "-1234.5")

        let a = try XCTUnwrap(form.find("a"))
        XCTAssertEqual(a.value, "-1234.5")
        XCTAssertEqual(try FormFixtures.drawn(form.document, a.widgets[0]), "(1,234.50)")
        XCTAssertEqual(form.displayText(a), "(1,234.50)")
        let ap = try XCTUnwrap(form.document.dict(a.widgets[0].dictionary, "AP"))
        let stream = try XCTUnwrap(form.document.resolve(ap["N"]) as? PdfStream)
        XCTAssertTrue(Latin1.string(try form.document.data(stream)).contains("1 0 0 rg"))
    }

    func test_calculationOrderRunsSumsAndTheirDependents() throws {
        let form = try build(
            total: js("C", "AFSimple_Calculate(\\\"SUM\\\", new Array(\\\"a\\\", \\\"b\\\"));") + " /DV (0)",
            acro: "/CO [12 0 R]")

        let result = try form.setValues([("a", "2"), ("b", "3.5")])

        XCTAssertEqual(result.calculated, 1)
        XCTAssertTrue(result.notRun.isEmpty)
        let total = try XCTUnwrap(form.find("total"))
        XCTAssertEqual(total.value, "5.5")
        XCTAssertEqual(try FormFixtures.drawn(form.document, total.widgets[0]), "5.5")
        XCTAssertEqual(form.calculationOrder.map { $0.name }, ["total"])
        try form.setValue("a", "10")
        XCTAssertEqual(form.find("total")?.value, "13.5")
    }

    func test_customJavaScriptIsListedAndNeverRun() throws {
        let form = try build(
            a: js("K", "AFNumber_Keystroke(2, 0, 0, 0, \\\"\\\", true);") + " /A <</S /JavaScript /JS (app.alert\\(1\\);)>>",
            total: js("C", "event.value = this.getField(\\\"a\\\").value * 2;"),
            acro: "/CO [12 0 R]",
            catalog: "/Names <</JavaScript <</Names [(init) <</S /JavaScript /JS (var x = 1;)>>]>>>>")

        let result = try form.setValue("a", "7")

        XCTAssertEqual(result.notRun.count, 1)
        let skipped = try XCTUnwrap(result.notRun.first)
        XCTAssertEqual(skipped.field, "total")
        XCTAssertFalse(skipped.builtIn)
        XCTAssertFalse(skipped.ran)
        XCTAssertNil(form.find("total")?.value)
        let scripts = form.scripts
        XCTAssertEqual(scripts.count, 4)
        XCTAssertTrue(scripts.contains { $0.event == "K" && $0.builtIn && $0.ran })
        XCTAssertTrue(scripts.contains { $0.event == "A" && !$0.builtIn && !$0.ran })
        XCTAssertTrue(scripts.contains { $0.field == nil && $0.event == "Names/init" && !$0.ran })
        XCTAssertTrue(scripts.contains { $0.event == "C" && $0.source.contains("getField") })
        XCTAssertFalse(FormText.scriptNotRun.isEmpty)
    }

    func test_validateAppliesKeystrokeAndRangeScripts() throws {
        let form = try build(a: js("V", "AFRange_Validate(true, 0, true, 100);"), b: js("K", "AFNumber_Keystroke(0, 0, 0, 0, \\\"\\\", true);"))

        XCTAssertNil(form.validate(try XCTUnwrap(form.find("a")), "50"))
        XCTAssertEqual(form.validate(try XCTUnwrap(form.find("a")), "500"), FormText.outOfRange("0", "100"))
        XCTAssertEqual(form.validate(try XCTUnwrap(form.find("b")), "x"), FormText.badNumber)
        XCTAssertNil(form.validate(try XCTUnwrap(form.find("total")), "anything"))
    }
}
