import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/standards/PdfUaRowsTests.cs, and drives the panel's model as the window does: the check,
// the offer to mark, and the marking itself.

@MainActor
final class PdfUaModelTests: XCTestCase {
    // One tagged figure with a description, a title and a language, and nothing that marking writes itself.
    private func markable() -> [UInt8] {
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        func obj(_ body: String) {
            offsets.append(out.count)
            out += Array("\(offsets.count) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let draw = "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC"
        obj("<</Type /Catalog /Pages 2 0 R /MarkInfo <</Marked true>> /Lang (en-US) /StructTreeRoot 5 0 R>>")
        obj("<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        obj("<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<>> /StructParents 0 /Tabs /S>>")
        obj("<</Length \(draw.utf8.count)>>\nstream\n\(draw)\nendstream")
        obj("<</Type /StructTreeRoot /K 6 0 R /ParentTree 8 0 R>>")
        obj("<</Type /StructElem /S /Document /P 5 0 R /K 7 0 R>>")
        obj("<</Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0 /Alt (A blue square)>>")
        obj("<</Nums [0 [7 0 R]]>>")
        obj("<</Title (Square) /Creator (Test) /Producer (Test)>>")
        let xref = out.count
        var table = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<</Size \(offsets.count + 1) /Root 1 0 R /Info 9 0 R /ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>]>>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    private func attached(_ bytes: [UInt8]? = nil) throws -> (model: PdfUaModel, rig: SecurityRig) {
        let rig = try SecurityRig(bytes)
        let model = PdfUaModel()
        rig.attach(model)
        return (model, rig)
    }

    func test_rowsNameTheMatterhornConditionAndTheClause() {
        let rows = IssueRow.group([
            PdfUaIssue("06-002", "14289-1 7.1", PdfAText.catalog, "The XMP metadata does not have pdfuaid:part with the value 1."),
            PdfUaIssue("13-004", "14289-1 7.3", PdfAText.pageName(2), "A Figure element has neither /Alt nor /ActualText."),
            PdfUaIssue("13-004", "14289-1 7.3", PdfAText.pageName(4), "A Figure element has neither /Alt nor /ActualText."),
        ])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].clause, "Matterhorn 06-002, ISO 14289-1 clause 14289-1 7.1")
        XCTAssertEqual(rows[1].place, "Page 2, and 1 more")
        XCTAssertFalse(rows[0].hasPlaces)
        XCTAssertEqual(rows[1].placeText, "Go to page 2")
    }

    func test_anUntaggedFileFailsAndCannotBeMarked() async throws {
        let (model, rig) = try attached()
        XCTAssertFalse(model.showsResult)

        await model.action!.run()

        XCTAssertTrue(model.showsResult)
        XCTAssertTrue(model.verdict.hasPrefix("Does not pass the checks for PDF/UA-1. Conditions broken: "))
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertFalse(model.canMark)
        XCTAssertEqual(rig.host.statuses.last, "Fails PDF/UA-1 checks.")
        XCTAssertEqual(rig.host.busyTexts, ["Checking PDF/UA-1"])
        XCTAssertFalse(model.working)
    }

    func test_aFileThatLacksOnlyTheIdentifierCanBeMarkedAndThenPasses() async throws {
        let (model, rig) = try attached(markable())

        await model.action!.run()

        XCTAssertTrue(model.canMark)
        XCTAssertFalse(rig.tab.isDirty)
        let conditions = Set(model.rows.map { $0.clause })
        XCTAssertTrue(conditions.allSatisfy { c in ["06-001", "06-002", "06-003", "07-001"].contains { c.contains("Matterhorn \($0),") } }, "\(conditions)")

        await model.mark()

        XCTAssertEqual(rig.host.notices.last?.title, "Marked as PDF/UA-1")
        XCTAssertTrue(rig.tab.isDirty)
        await waitUntil { model.showsResult && model.verdict.hasPrefix("Passes") }
        XCTAssertFalse(model.canMark)
        XCTAssertEqual(model.verdict, "Passes Lazy PDF's checks for PDF/UA-1.")
        XCTAssertEqual(rig.host.statuses.last, "Passes Lazy PDF's PDF/UA-1 checks.")
    }

    func test_aVerdictGoesWhenTheFileChanges() async throws {
        let (model, rig) = try attached()
        await model.action!.run()
        XCTAssertTrue(model.showsResult)

        try Pdfs.retitle(rig.tab.session, "Changed")
        try rig.tab.commit("Title")
        await waitUntil { !model.showsResult }
    }
}
