import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAOptionalContentTests.cs: the same cases.

final class PdfAOptionalContentTests: XCTestCase {
    private func withLayers(_ properties: String, _ level: PdfALevel = .a2b) -> [UInt8] {
        StandardsKit.compliant(level, catalog: "/OCProperties \(properties)", extra: { pdf in pdf.obj(9, "<</Type /OCG /Name (Layer)>>") })
    }

    private let good = "<< /OCGs [9 0 R] /D << /Name (Default) /Order [9 0 R] >> >>"

    func test_part1ForbidsOptionalContentAndLaterPartsAllowIt() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withLayers(good, .a1b), .a1b), "6.1.13")
        try StandardsKit.assertClean(withLayers(good))
        try StandardsKit.assertClean(withLayers(good, .a3b), .a3b)
    }

    func test_everyConfigurationNeedsAUniqueName() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withLayers("<< /OCGs [9 0 R] /D << /Order [9 0 R] >> >>")), "6.9")
        StandardsKit.assertHas(try StandardsKit.check(withLayers("<< /OCGs [9 0 R] /D << /Name (A) >> /Configs [<< /Name (A) >>] >>")).issues) { $0.message.contains("same name") }
        StandardsKit.assertLacks(try StandardsKit.clauses(withLayers("<< /OCGs [9 0 R] /D << /Name (A) >> /Configs [<< /Name (B) >>] >>")), "6.9")
    }

    func test_anAutomaticStateIsReported() throws {
        StandardsKit.assertHas(try StandardsKit.check(withLayers("<< /OCGs [9 0 R] /D << /Name (A) /AS [<< /Event /View >>] >> >>")).issues) { $0.message.contains("/AS") }
    }

    func test_theOrderHasToListEveryGroup() throws {
        StandardsKit.assertHas(try StandardsKit.check(withLayers("<< /OCGs [9 0 R] /D << /Name (A) /Order [] >> >>")).issues) { $0.message.contains("/Order") }
        try StandardsKit.assertClean(withLayers("<< /OCGs [9 0 R] /D << /Name (A) /Order [[(Group) 9 0 R]] >> >>"))
    }
}
