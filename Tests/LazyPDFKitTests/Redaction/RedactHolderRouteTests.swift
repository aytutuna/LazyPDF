import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactHolderRouteTests.cs: the same cases. What a page keeps alive is what its
// content paints, through the keys that mean it. A name, a list or a private key that points at the cut picture or the old
// content keeps nothing.

final class RedactHolderRouteTests: XCTestCase {
    private let picture = RedactionFiles.picture
    private let overBoth = PdfRect(90, 90, 300, 130)
    private var both: String { RedactionFiles.word + " " + picture }

    private func redact(_ document: PdfDocument) throws -> RedactionResult {
        try RedactionFiles.apply(document, RedactionMark.fromRect(0, overBoth))
    }

    func test_nameThatPointsAtTheCutPictureKeepsNothing() throws {
        let cases = [("/Tag /P0 BDC EMC", "/Properties <</P0 6 0 R>>", ""), ("/C0 cs", "/ColorSpace <</C0 6 0 R>>", ""),
                     ("BT /F2 12 Tf 400 600 Td (hello) Tj ET", "", "/F2 7 0 R")]
        for (use, resources, fonts) in cases {
            let document = try RedactionFiles.open(picture + " " + use, "/XObject <</Im1 6 0 R>> " + resources, { pdf in
                RedactionFiles.image(pdf, 6)
                pdf.obj(7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode 6 0 R>>")
            }, fonts: fonts)
            RedactionFiles.gone(try redact(document), "ZQXPIXELS")
        }
    }

    func test_formListingKeysOfItsOwnKeepsNothing() throws {
        let document = try RedactionFiles.open(both + " /Fm2 Do", "/XObject <</Im1 6 0 R /Fm2 7 0 R>>") { pdf in
            RedactionFiles.image(pdf, 6)
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</K1 6 0 R /K2 31 0 R>>", "0 0 1 1 re f")
        }
        RedactionFiles.gone(try redact(document), "ZQXPIXELS", "ZQXSECRET")
    }

    func test_formWhoseResourcesAreAPictureKeepsNothing() throws {
        let document = try RedactionFiles.open(both + " /Fm2 Do", "/XObject <</Im1 6 0 R /Fm2 7 0 R>>") { pdf in
            RedactionFiles.image(pdf, 6)
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources 6 0 R", "0 0 1 1 re f")
        }
        RedactionFiles.gone(try redact(document), "ZQXPIXELS", "ZQXSECRET")
    }

    func test_procSetThatIsAPictureKeepsNothing() throws {
        let document = try RedactionFiles.open(both, "/XObject <</Im1 6 0 R>> /ProcSet 6 0 R") { pdf in RedactionFiles.image(pdf, 6) }
        RedactionFiles.gone(try redact(document), "ZQXPIXELS", "ZQXSECRET")
    }

    func test_pageKeysThatHoldNoStreamKeepNothing() throws {
        for extra in ["/Group <</S /Transparency /X <</CS [31 0 R 6 0 R]>>>>", "/TrimBox [0 0 600 800 31 0 R 6 0 R]", "/Group 31 0 R"] {
            let document = try RedactionFiles.open(both, "/XObject <</Im1 6 0 R>>", { pdf in RedactionFiles.image(pdf, 6) }, pageExtra: extra)
            RedactionFiles.gone(try redact(document), "ZQXPIXELS", "ZQXSECRET")
        }
    }

    func test_privateKeyAboveAPaintKeyKeepsNothing() throws {
        let document = try RedactionFiles.open(both + " /Fm2 Do", "/XObject <</Im1 6 0 R /Im2 7 0 R /Fm2 8 0 R>>") { pdf in
            RedactionFiles.image(pdf, 6)
            RedactionFiles.image(pdf, 7, "/Private <</SMask 6 0 R /Mask 31 0 R>>", "ZQXOTHERS")
            pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</Im2 7 0 R>>>>", "q 5 0 0 5 400 600 cm /Im2 Do Q")
        }
        RedactionFiles.gone(try redact(document), "ZQXPIXELS", "ZQXSECRET")
    }

    func test_pageTreeNodeUsedAsAListStillReachesThePicture() throws {
        for node in [1, 2] {
            let document = try RedactionFiles.open(picture, "/XObject \(node) 0 R", { pdf in RedactionFiles.image(pdf, 6) },
                                                   catalogExtra: node == 1 ? "/Im1 6 0 R" : "", pagesExtra: node == 2 ? "/Im1 6 0 R" : "")
            RedactionFiles.gone(try RedactionFiles.apply(document, RedactionMark.fromRect(0, PdfRect(90, 90, 250, 250))), "ZQXPIXELS")
        }
    }

    func test_globalsOfAnUnmarkedPagesImageStay() throws {
        let entries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 10 0 R>>"
        let document = try RedactionFiles.open([RedactionFiles.word + " /Im1 Do", "/Im2 Do"], "/XObject <</Im1 6 0 R /Im2 7 0 R>>", { pdf in
            pdf.stream(6, entries, "xx")
            pdf.stream(7, entries, "yy")
            pdf.stream(10, "", "GLOBALDATA")
        })
        let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, RedactionFiles.over))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        XCTAssertTrue(RedactionKit.holds(result.bytes, "GLOBALDATA"))
    }

    func test_threadOfAnUnmarkedPageStays() throws {
        let document = try RedactionFiles.open([RedactionFiles.word, "BT ET"], "", { pdf in
            pdf.obj(8, "<</T 10 0 R /N 9 0 R /V 9 0 R /P 30 0 R /R [0 0 100 100]>>")
            pdf.obj(9, "<</T 10 0 R /N 8 0 R /V 8 0 R /P 32 0 R /R [0 0 100 100]>>")
            pdf.obj(10, "<</F 8 0 R /I <</Title (Thread)>>>>")
        }, pageExtras: ["/B [8 0 R]", "/B [9 0 R]"], catalogExtra: "/Threads [10 0 R]")
        let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, RedactionFiles.over))
        let output = try RedactionKit.open(result)
        let beads = try XCTUnwrap(output.resolve(output.pages[1].dictionary["B"]) as? PdfArray)
        let bead = try XCTUnwrap(output.resolve(beads.items[0]) as? PdfDictionary)
        XCTAssertTrue(bead.containsKey("T"))
        XCTAssertTrue(try XCTUnwrap(output.resolve(bead["T"]) as? PdfDictionary).count > 0)
    }

    func test_pageThatIsAlsoANodeWithKidsKeepsItsResources() throws {
        let document = try RedactionFiles.open(picture, "/XObject <</Im1 6 0 R>>", { pdf in RedactionFiles.image(pdf, 6) }, pageExtra: "/Kids []")
        let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, PdfRect(90, 90, 250, 250)))
        XCTAssertEqual(result.report.pages.reduce(0) { $0 + $1.images }, 1)
        RedactionFiles.gone(result, "ZQXPIXELS")
    }
}
