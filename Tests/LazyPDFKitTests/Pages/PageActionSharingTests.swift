import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageActionSharingTests.cs: the same cases. The C# gives the two big cases 10
// seconds with Task.Run and WaitAsync; here a run that does not end is the runner's timeout.

final class PageActionSharingTests: XCTestCase {
    private func dict(_ document: PdfDocument, _ number: Int) throws -> PdfDictionary {
        try XCTUnwrap(document.get(number) as? PdfDictionary)
    }

    func test_aDeadGoToAtTheDepthLimitLeavesNoFollowerThatIsNotAnAction() throws {
        for next in ["[]", "[1 2]", "[(x)]", "7", "(x)"] {
            let document = try PageTestFiles.open(2, "/OpenAction 20 0 R", add: { pdf in
                for i in 0..<32 { pdf.obj(20 + i, "<</S /URI /URI (http://a) /Next \(21 + i) 0 R>>") }
                pdf.obj(52, "<</S /GoTo /D [5 0 R /Fit] /Next \(next)>>")
            })

            try PageOperations.delete(document, [1])

            XCTAssertFalse(try dict(document, 51).containsKey("Next"), next)
        }
    }

    func test_actionsAreDictionariesAfterTheirGoToIsDropped() throws {
        for next in ["7", "(x)", "[7 (x)]"] {
            let document = try PageTestFiles.open(2, "/OpenAction 20 0 R", pageExtra: { $0 == 0 ? "/Annots [90 0 R]" : "" }, add: { pdf in
                pdf.obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next \(next)>>")
                    .obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>")
            })

            try PageOperations.delete(document, [1])

            XCTAssertNil(document.catalog["OpenAction"], next)
            XCTAssertFalse(try dict(document, 90).containsKey("A"), next)
        }
    }

    func test_anActionSharedByTwoLinksIsNotEditedForEach() throws {
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [90 0 R 91 0 R]" : "" }, add: { pdf in
            pdf.obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>")
                .obj(91, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>")
                .obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next [21 0 R 22 0 R]>>")
                .obj(21, "<</S /URI /URI (http://a)>>")
                .obj(22, "<</S /URI /URI (http://b)>>")
        })

        try PageOperations.delete(document, [1])

        XCTAssertFalse(try dict(document, 21).containsKey("Next"))
        for link in [90, 91] {
            let action = try XCTUnwrap(document.resolve(try dict(document, link)["A"]) as? PdfDictionary)
            XCTAssertEqual(PageTestFiles.text(action["URI"]), "http://a")
            let rest = try XCTUnwrap(document.resolve(action["Next"]) as? PdfArray)
            XCTAssertEqual(rest.items.count, 1)
            XCTAssertEqual(rest.items.first as? PdfReference, PdfReference(22, 0))
        }
    }

    func test_aLiveLinkDoesNotGainTheFollowersOfADeadAction() throws {
        let document = try PageTestFiles.open(2, "/OpenAction 20 0 R", pageExtra: { $0 == 0 ? "/Annots [90 0 R]" : "" }, add: { pdf in
            pdf.obj(90, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 21 0 R>>")
                .obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next [21 0 R 22 0 R]>>")
                .obj(21, "<</S /URI /URI (http://a)>>")
                .obj(22, "<</S /URI /URI (http://b)>>")
        })

        try PageOperations.delete(document, [1])

        XCTAssertFalse(try dict(document, 21).containsKey("Next"))
    }

    func test_followersMergedIntoOneActionNeverMakeALoop() throws {
        for (next, back) in [("[21 0 R 21 0 R]", ""), ("[21 0 R 22 0 R]", "/Next 21 0 R")] {
            let document = try PageTestFiles.open(2, "/OpenAction 20 0 R", add: { pdf in
                pdf.obj(20, "<</S /GoTo /D [5 0 R /Fit] /Next \(next)>>")
                    .obj(21, "<</S /URI /URI (http://a)>>")
                    .obj(22, "<</S /URI /URI (http://b) \(back)>>")
            })

            try PageOperations.delete(document, [1])

            XCTAssertFalse(try dict(document, 21).containsKey("Next"), next)
        }
    }

    func test_manyLinksSharingOneActionWithManyFollowersEnds() throws {
        let links = 20_000
        let annots = (0..<links).map { "\(1000 + $0) 0 R" }.joined(separator: " ")
        let followers = (0..<links).map { "\(1000 + links + $0) 0 R" }.joined(separator: " ")
        let document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/Annots [\(annots)]" : "" }, add: { pdf in
            pdf.obj(20, "<</S /URI /URI (http://a) /Next [\(followers)]>>")
            for n in 0..<links {
                pdf.obj(1000 + n, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /A 20 0 R>>")
                pdf.obj(1000 + links + n, "<</S /URI /URI (http://b)>>")
            }
        })

        try PageOperations.delete(document, [1])

        XCTAssertEqual(document.pages.count, 1)
    }

    func test_aThreadListedManyTimesIsWalkedOnce() throws {
        let beads = 20_000
        let free = PageTestFiles.free(2)
        let listed = Array(repeating: "\(free) 0 R", count: beads).joined(separator: " ")
        let document = try PageTestFiles.open(2, "/Threads [\(listed)]", add: { pdf in
            pdf.obj(free, "<</Type /Thread /F \(free + 1) 0 R>>")
            for i in 0..<beads {
                let next = free + 1 + (i + 1) % beads, previous = free + 1 + (i + beads - 1) % beads
                pdf.obj(free + 1 + i, "<</Type /Bead /N \(next) 0 R /V \(previous) 0 R /P \(i == 0 ? 5 : 4) 0 R /R [0 0 1 1]>>")
            }
        })

        try PageOperations.delete(document, [1])

        let thread = try dict(document, free)
        XCTAssertEqual(thread["F"] as? PdfReference, PdfReference(free + 2, 0))
    }

    func test_twoThreadsOnTheSameBeadsBothGoWithThem() throws {
        let free = PageTestFiles.free(2)
        let document = try PageTestFiles.open(2, "/Threads [\(free) 0 R \(free + 1) 0 R]", add: { pdf in
            pdf.obj(free, "<</Type /Thread /F \(free + 2) 0 R>>")
                .obj(free + 1, "<</Type /Thread /F \(free + 2) 0 R>>")
                .obj(free + 2, "<</Type /Bead /N \(free + 3) 0 R /V \(free + 3) 0 R /P 5 0 R /R [0 0 1 1]>>")
                .obj(free + 3, "<</Type /Bead /N \(free + 2) 0 R /V \(free + 2) 0 R /P 5 0 R /R [0 0 1 1]>>")
        })

        try PageOperations.delete(document, [1])

        XCTAssertEqual(try XCTUnwrap(document.array(document.catalog, "Threads")).items.count, 0)
    }
}
