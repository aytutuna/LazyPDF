import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageActionWalkTests.cs: the same cases.

final class PageActionWalkTests: XCTestCase {
    private func dict(_ document: PdfDocument, _ number: Int) throws -> PdfDictionary {
        try XCTUnwrap(document.get(number) as? PdfDictionary)
    }

    func test_linksWithTheirOwnActionsShareOneFollowerArray() throws {
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [90 0 R 91 0 R]" : "" }, add: { pdf in
            pdf.obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
                .obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 31 0 R>>")
                .obj(30, "<</S /URI /URI (http://a) /Next 20 0 R>>")
                .obj(31, "<</S /URI /URI (http://b) /Next 20 0 R>>")
                .obj(20, "[21 0 R 22 0 R]")
                .obj(21, "<</S /GoTo /D [5 0 R /Fit]>>")
                .obj(22, "<</S /URI /URI (http://c)>>")
        })

        try PageOperations.delete(document, [1])

        let first = document.resolve(try dict(document, 30)["Next"])
        let second = document.resolve(try dict(document, 31)["Next"])
        assertSame(first, second)
        let list = try XCTUnwrap(first as? PdfArray)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items.first as? PdfReference, PdfReference(22, 0))
    }

    func test_anArrayOfLiveActionsIsLeftAsItIs() throws {
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [90 0 R]" : "" }, add: { pdf in
            pdf.obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
                .obj(30, "<</S /URI /URI (http://a) /Next 20 0 R>>")
                .obj(20, "[21 0 R 22 0 R]")
                .obj(21, "<</S /URI /URI (http://b)>>")
                .obj(22, "<</S /URI /URI (http://c)>>")
        })

        try PageOperations.delete(document, [1])

        XCTAssertEqual(try dict(document, 30)["Next"] as? PdfReference, PdfReference(20, 0))
    }

    func test_anActionCutShortAtTheDepthLimitIsWalkedAgainFromALiveLink() throws {
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [90 0 R 91 0 R]" : "" }, add: { pdf in
            pdf.obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 100 0 R>>")
            pdf.obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 132 0 R>>")
            for i in 0..<32 { pdf.obj(100 + i, "<</S /URI /URI (http://a) /Next \(101 + i) 0 R>>") }
            pdf.obj(132, "<</S /URI /URI (http://x) /Next 133 0 R>>")
            pdf.obj(133, "<</S /GoTo /D [5 0 R /Fit]>>")
        })

        try PageOperations.delete(document, [1])

        XCTAssertFalse(try dict(document, 132).containsKey("Next"))
    }

    func test_linksWhoseGoToIsDroppedShareOneLead() throws {
        let links = 300
        let annots = (0..<links).map { "\(1000 + $0) 0 R" }.joined(separator: " ")
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [\(annots)]" : "" }, add: { pdf in
            for n in 0..<links {
                pdf.obj(1000 + n, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A \(2000 + n) 0 R>>")
                pdf.obj(2000 + n, "<</S /GoTo /D [5 0 R /Fit] /Next 20 0 R>>")
            }
            pdf.obj(20, "[21 0 R 22 0 R 23 0 R]")
            for n in 21...23 { pdf.obj(n, "<</S /URI /URI (http://a)>>") }
        })

        try PageOperations.delete(document, [1])

        let first = try XCTUnwrap(try dict(document, 1000)["A"] as? PdfReference)
        XCTAssertEqual(try dict(document, 1000 + links - 1)["A"] as? PdfReference, first)
        let next = try XCTUnwrap(document.resolve(try dict(document, first.number)["Next"]) as? PdfArray)
        XCTAssertEqual(next.items.count, 2)
    }

    func test_aDroppedMemberLeavesTheSharedArrayInPlaceForEveryHolder() throws {
        let links = 200
        let annots = (0..<links).map { "\(1000 + $0) 0 R" }.joined(separator: " ")
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [\(annots)]" : "" }, add: { pdf in
            for n in 0..<links {
                pdf.obj(1000 + n, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A \(2000 + n) 0 R>>")
                pdf.obj(2000 + n, "<</S /URI /URI (http://a) /Next 20 0 R>>")
                pdf.obj(3000 + n, n == 0 ? "<</S /GoTo /D [5 0 R /Fit]>>" : "<</S /URI /URI (http://b)>>")
            }
            pdf.obj(20, "[" + (0..<links).map { "\(3000 + $0) 0 R" }.joined(separator: " ") + "]")
        })

        try PageOperations.delete(document, [1])

        for n in 0..<links { XCTAssertEqual(try dict(document, 2000 + n)["Next"] as? PdfReference, PdfReference(20, 0)) }
        XCTAssertEqual(try XCTUnwrap(document.get(20) as? PdfArray).items.count, links - 1)
    }

    func test_anArrayWhoseMembersAreMetThroughAnotherHolderIsLeftAsItIs() throws {
        for array in ["[21 0 R 22 0 R]", "[21 0 R 21 0 R]"] {
            let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [89 0 R 90 0 R]" : "" }, add: { pdf in
                pdf.obj(89, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 21 0 R>>")
                    .obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
                    .obj(30, "<</S /URI /URI (http://a) /Next 20 0 R>>")
                    .obj(20, array)
                    .obj(21, "<</S /URI /URI (http://b)>>")
                    .obj(22, "<</S /URI /URI (http://c)>>")
            })

            try PageOperations.delete(document, [1])

            XCTAssertEqual(try dict(document, 30)["Next"] as? PdfReference, PdfReference(20, 0), array)
            XCTAssertEqual(try XCTUnwrap(document.get(20) as? PdfArray).items.count, 2, array)
        }
    }

    func test_anArrayCutShortAtTheDepthLimitIsWalkedAgainFromALiveLink() throws {
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [90 0 R 91 0 R]" : "" }, add: { pdf in
            pdf.obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 100 0 R>>")
            pdf.obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 200 0 R>>")
            for i in 0..<31 { pdf.obj(100 + i, "<</S /URI /URI (http://a) /Next \(101 + i) 0 R>>") }
            pdf.obj(131, "<</S /URI /URI (http://a) /Next 20 0 R>>")
            pdf.obj(200, "<</S /URI /URI (http://z) /Next 20 0 R>>")
            pdf.obj(20, "[132 0 R]")
            pdf.obj(132, "<</S /URI /URI (http://x) /Next 133 0 R>>")
            pdf.obj(133, "<</S /GoTo /D [5 0 R /Fit]>>")
        })

        try PageOperations.delete(document, [1])

        XCTAssertFalse(try dict(document, 132).containsKey("Next"))
    }

    func test_anActionThatLoopsBackToADroppedGoToDoesNotKeepIt() throws {
        for annots in ["90 0 R 91 0 R", "91 0 R 90 0 R"] {
            let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [\(annots)]" : "" }, add: { pdf in
                pdf.obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 30 0 R>>")
                    .obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 32 0 R>>")
                    .obj(30, "<</S /GoTo /D [5 0 R /Fit] /Next 31 0 R>>")
                    .obj(31, "<</S /URI /URI (http://u) /Next 30 0 R>>")
                    .obj(32, "<</S /URI /URI (http://w) /Next 31 0 R>>")
            })

            try PageOperations.delete(document, [1])

            XCTAssertNotEqual(try dict(document, 31)["Next"] as? PdfReference, PdfReference(30, 0), annots)
            XCTAssertNotEqual(try dict(document, 90)["A"] as? PdfReference, PdfReference(30, 0), annots)
        }
    }
}
