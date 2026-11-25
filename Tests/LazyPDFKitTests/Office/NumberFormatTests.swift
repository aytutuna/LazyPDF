import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/NumberFormatTests.cs and reads the same table, office-xlsx/numfmt.txt.

final class NumberFormatTests: XCTestCase {
    func test_numberFormatTable() throws {
        var failures = ""
        var date1904 = false
        var checks = 0
        for line in try Golden.input("office-xlsx", "numfmt.txt").components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("!") {
                date1904 = line == "!1904"
                continue
            }
            checks += 1
            let cells = line.components(separatedBy: "\t")
            let format = NumberFormat.parse(cells[1])
            let result = cells[0].hasPrefix("'")
                ? format.formatText(String(cells[0].dropFirst()))
                : format.format(Double(cells[0])!, date1904: date1904)
            let actual = result.text + (result.color.map { "\t" + String($0, radix: 16).leftPad(6) } ?? "")
            let expected = cells[2] + (cells.count > 3 ? "\t" + cells[3] : "")
            if actual != expected { failures += "\(cells[0]) | \(cells[1]) | expected [\(expected)] got [\(actual)]\n" }
        }
        XCTAssertEqual(failures, "")
        XCTAssertGreaterThan(checks, 120)
    }

    func test_builtInFormatsCoverTheKnownIds() {
        for id in 0...49 {
            let code = NumberFormat.builtInCode(id)
            if (23...36).contains(id) { XCTAssertNil(code) } else { XCTAssertNotNil(code) }
        }
        XCTAssertNil(NumberFormat.builtInCode(50))
        XCTAssertEqual(NumberFormat.parse(NumberFormat.builtInCode(14)!).format(43832, date1904: false).text, "1/2/2020")
        XCTAssertEqual(NumberFormat.parse(NumberFormat.builtInCode(4)!).format(1234.5, date1904: false).text, "1,234.50")
    }

    func test_oddCodesDoNotCrash() {
        for code in ["", ";;;;;", "[", "\"", "\\", "_", "*", "[>", "0.0.0", "E+", "0E+", "?/", "/?", "[$", "[Red", "0;0;0;0;0", "#,#,#", ",", "0,", "[h", "yyyy.000000", "General General"] {
            let format = NumberFormat.parse(code)
            for v in [0, 1, -1, 0.5, 1e300, -1e-300, 45000.5] { _ = format.format(v, date1904: false) }
            _ = format.formatText("text")
        }
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}
