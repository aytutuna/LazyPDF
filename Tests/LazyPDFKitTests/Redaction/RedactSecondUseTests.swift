import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactSecondUseTests.cs: the same cases. A picture, form or mask that is cut at
// a mark is a copy; every other use of it, wherever it is, still names the original.

final class RedactSecondUseTests: XCTestCase {
    private let stamp = "<</Type /Annot /Subtype /Stamp /Rect [500 700 501 701] /F 4 /AP <</N 7 0 R>>>>"
    private let overPicture = PdfRect(90, 90, 250, 250)

    private func appearance(_ pdf: TestPdf, _ resources: String, _ content: String) {
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources <<\(resources)>>", content)
    }

    func test_annotationAppearanceThatPaintsTheCutPictureMakesAPicture() throws {
        let document = try RedactionFiles.open(RedactionFiles.picture, "/XObject <</Im1 6 0 R>>", { pdf in
            RedactionFiles.image(pdf, 6)
            self.appearance(pdf, "/XObject <</Im1 6 0 R>>", "/Im1 Do")
            pdf.obj(8, self.stamp)
        }, pageExtra: "/Annots [8 0 R]")
        try RedactionKit.assertFlattened(document, overPicture, "ZQXPIXELS")
    }

    func test_annotationAppearanceThatIsTheCutFormMakesAPicture() throws {
        let document = try RedactionFiles.open("/Fm1 Do", "/XObject <</Fm1 6 0 R>>", { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", RedactionFiles.word)
            pdf.obj(8, "<</Type /Annot /Subtype /Stamp /Rect [500 700 501 701] /F 4 /AP <</N 6 0 R>>>>")
        }, pageExtra: "/Annots [8 0 R]")
        try RedactionKit.assertFlattened(document, RedactionFiles.over, "ZQXSECRET")
    }

    func test_pictureStaysCutWhenNoAnnotationShowsIt() throws {
        let document = try RedactionFiles.open(RedactionFiles.picture, "/XObject <</Im1 6 0 R>>", { pdf in RedactionFiles.image(pdf, 6) })
        let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, overPicture))
        XCTAssertTrue(result.report.flattened.isEmpty)
        RedactionFiles.gone(result, "ZQXPIXELS")
    }

    func test_maskHeldByAPictureOffTheMarkMakesAPicture() throws {
        let mask = "/SMask 8 0 R"
        let document = try RedactionFiles.open(RedactionFiles.picture + " q 20 0 0 20 400 600 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>", { pdf in
            RedactionFiles.image(pdf, 6, mask)
            RedactionFiles.image(pdf, 7, mask, "ZQXOTHERS")
            RedactionFiles.image(pdf, 8, "", "ZQXMASKED")
        })
        try RedactionKit.assertFlattened(document, overPicture, "ZQXMASKED", "ZQXPIXELS")
    }

    func test_cutPictureThatIsTheMaskOfAnotherMakesAPicture() throws {
        let document = try RedactionFiles.open(RedactionFiles.picture + " q 20 0 0 20 400 600 cm /Im2 Do Q", "/XObject <</Im1 6 0 R /Im2 7 0 R>>", { pdf in
            RedactionFiles.image(pdf, 6)
            RedactionFiles.image(pdf, 7, "/SMask 6 0 R", "ZQXOTHERS")
        })
        try RedactionKit.assertFlattened(document, overPicture, "ZQXPIXELS")
    }

    func test_useOnAnotherMarkedPageMakesThatPageAPicture() throws {
        for form in [false, true] {
            let use = form ? "/Fm1 Do" : "/Im1 Do"
            let first = form ? "/Fm1 Do" : RedactionFiles.picture
            let document = try RedactionFiles.open([first, "q 5 0 0 5 5000 5000 cm " + use + " Q"], "/XObject <</Im1 6 0 R /Fm1 7 0 R>>", { pdf in
                RedactionFiles.image(pdf, 6)
                pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", RedactionFiles.word)
            })
            let marks = [RedactionMark.fromRect(0, form ? RedactionFiles.over : overPicture), RedactionMark.fromRect(1, PdfRect(400, 600, 450, 650))]
            let result = try RedactionKit.apply(document, marks)
            XCTAssertTrue(result.report.flattened.contains(1), "\(form)")
            RedactionFiles.gone(result, form ? "ZQXSECRET" : "ZQXPIXELS")
        }
    }

    func test_appearanceOnAKeptAnnotationOfAnUnmarkedPageThatCannotBeFollowedIsReported() throws {
        let document = try RedactionFiles.open([RedactionFiles.picture, "BT ET"], "/XObject <</Im1 6 0 R>>", { pdf in
            RedactionFiles.image(pdf, 6)
            self.appearance(pdf, "/XObject <</Im1 6 0 R>>", "% not a whole token\n")
            pdf.obj(8, self.stamp)
        }, pageExtras: ["", "/Annots [8 0 R]"])
        let result = try RedactionFiles.apply(document, RedactionMark.fromRect(0, overPicture))
        XCTAssertFalse(result.verification.isClean)
        XCTAssertTrue(result.verification.problems.contains(RedactionText.notFollowed(1)))
    }
}
