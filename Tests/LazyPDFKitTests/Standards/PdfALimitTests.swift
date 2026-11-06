import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfALimitTests.cs: the same cases.

final class PdfALimitTests: XCTestCase {
    private func withPageEntry(_ entry: String, _ level: PdfALevel = .a2b) -> [UInt8] { StandardsKit.compliant(level, page: entry) }

    private func deviceN(_ colorants: Int, _ level: PdfALevel) -> [UInt8] {
        StandardsKit.compliant(level, resources: "/ColorSpace <</CS0 [/DeviceN [" + (0..<colorants).map { "/C\($0)" }.joined(separator: " ") + "] /DeviceRGB 9 0 R]>>", extra: { pdf in
            pdf.stream(9, "/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1]", "{}")
        })
    }

    func test_partOneAllowsEightColorantsAndLaterPartsThirtyTwo() throws {
        StandardsKit.assertHas(try StandardsKit.check(deviceN(12, .a1b), .a1b).issues) { $0.clause == "6.1.12" && $0.message.contains("more than 8") }
        StandardsKit.assertLacks(try StandardsKit.clauses(deviceN(8, .a1b), .a1b), "6.1.12")
        StandardsKit.assertLacks(try StandardsKit.clauses(deviceN(12, .a2b)), "6.1.13")
        StandardsKit.assertContains(try StandardsKit.clauses(deviceN(33, .a2b)), "6.1.13")
    }

    func test_partOneBoundsRealNumbers() throws {
        StandardsKit.assertHas(try StandardsKit.check(withPageEntry("/Extra 40000.5", .a1b), .a1b).issues) { $0.clause == "6.1.12" && $0.message.contains("40000.5") }
        try StandardsKit.assertClean(withPageEntry("/Extra 32767 /Other -20000.5 /Third 1000000", .a1b), .a1b)
        StandardsKit.assertLacks(try StandardsKit.clauses(withPageEntry("/Extra 40000.5")), "6.1.13")
    }

    func test_limitsApplyToValuesInContentStreams() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a1b, content: "0 0 1 rg 20 20 40000.5 100 re f"), .a1b), "6.1.12")
        let longName = String(repeating: "N", count: 130)
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "/\(longName) gs 0 0 1 rg 20 20 100 100 re f")), "6.1.13")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "2147483648 0 0 1 rg 20 20 100 100 re f")), "6.1.13")
        try StandardsKit.assertClean(StandardsKit.compliant(content: "-2147483648 0 0 1 rg 20 20 100 100 re f"))
    }

    func test_limitsApplyToTheDictionaryOfAnInlineImage() throws {
        let image = "BI /W 1 /H 1 /BPC 8 /CS /G /D [0 40000.5] ID a EI"
        StandardsKit.assertHas(try StandardsKit.check(StandardsKit.compliant(.a1b, content: image), .a1b).issues) { $0.clause == "6.1.12" && $0.message.contains("40000.5") }
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(content: image)), "6.1.13")
    }

    func test_theLowestIntegerIsInRange() throws {
        try StandardsKit.assertClean(withPageEntry("/Extra -2147483648"))
        StandardsKit.assertContains(try StandardsKit.clauses(withPageEntry("/Extra -2147483649")), "6.1.13")
        StandardsKit.assertContains(try StandardsKit.clauses(withPageEntry("/Extra 2147483648")), "6.1.13")
    }

    func test_contentPastTheOperationLimitIsReportedAndNotRun() throws {
        let content = String(repeating: "n ", count: 10_100_000)
        let issues = try StandardsKit.check(StandardsKit.compliant(content: content)).issues
        StandardsKit.assertHas(issues) { $0.where == "Page 1" && $0.message == PdfAText.contentUnreadable }
    }

    func test_appearancesSharedByManyAnnotationsAreRunOnce() throws {
        let refs = (0..<400).map { "\(20 + $0) 0 R" }.joined(separator: " ")
        let file = StandardsKit.compliant(page: "/Annots [\(refs)]", extra: { pdf in
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "0 0 1 rg 0 0 5 5 re f")
            pdf.obj(11, "<</N 10 0 R>>")
            for i in 0..<400 { pdf.obj(20 + i, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP 11 0 R>>") }
        })
        try StandardsKit.assertClean(file)
    }

    func test_hexStringsNeedAnEvenCountOfHexDigits() throws {
        StandardsKit.assertHas(try StandardsKit.check(withPageEntry("/Extra <ABC>")).issues) { $0.clause == "6.1.6" }
        StandardsKit.assertHas(try StandardsKit.check(withPageEntry("/Extra <AB CD G1>")).issues) { $0.clause == "6.1.6" }
        StandardsKit.assertContains(try StandardsKit.clauses(withPageEntry("/Extra <ABC>", .a1b), .a1b), "6.1.6")
        try StandardsKit.assertClean(withPageEntry("/Extra <AB CD 01> /More (<ABC) /Third [<>] /Name /stream"))
    }

    func test_aStreamKeywordTakesNoSpaceAndEndstreamNeedsALineBefore() throws {
        let data = "0 0 1 rg 20 20 100 100 re f"
        let space = StandardsKit.compliant(extra: { pdf in pdf.obj(4, "<</Length \(data.count)>>\nstream \n\(data)\nendstream") })
        StandardsKit.assertHas(try StandardsKit.check(space).issues) { $0.clause == "6.1.7" && $0.message.contains("stream keyword") }

        let crlf = StandardsKit.compliant(extra: { pdf in pdf.obj(4, "<</Length \(data.count)>>\nstream\r\n\(data)\nendstream") })
        StandardsKit.assertNone(try StandardsKit.check(crlf).issues) { $0.message.contains("stream keyword") }

        let glued = StandardsKit.compliant(extra: { pdf in pdf.obj(4, "<</Length \(data.count)>>\nstream\n\(data)endstream") })
        StandardsKit.assertHas(try StandardsKit.check(glued).issues) { $0.clause == "6.1.7" && $0.message.contains("/Length") }

        let good = StandardsKit.compliant(extra: { pdf in pdf.obj(4, "<</Length \(data.count)>>\nstream\n\(data)\r\nendstream") })
        StandardsKit.assertNone(try StandardsKit.check(good).issues) { $0.clause == "6.1.7" }
    }
}
