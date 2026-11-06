import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeReachTests.cs: the same cases (places that actions, hidden content
// and file names can live). The PdfPig page count of NamedAndTemplatePagesGoWithTheScripts has no twin; the engine's page
// count stands in for it.

final class SanitizeReachTests: XCTestCase {
    private func file(_ catalogExtra: String, _ pageExtra: String, _ more: [(number: Int, body: String)]) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogExtra)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R \(pageExtra)>>")
        for (number, body) in more { pdf.obj(number, body) }
        return pdf.finish()
    }

    private func run(_ file: [UInt8], _ options: SanitizeOptions = SanitizeOptions()) throws -> SanitizeResult {
        let document = try PdfDocument.open(file)
        return try PdfSanitizer(document).run(options)
    }

    func test_aVeryLongActionChainDoesNotOverflowTheStack() throws {
        let length = 30_000
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction 100 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        for i in 0..<length { pdf.obj(100 + i, "<</S /Named /N /NextPage /Next \(101 + i) 0 R>>") }
        pdf.obj(100 + length, "<</S /JavaScript /JS (MARKERJS1)>>")
        let document = try PdfDocument.open(pdf.finish())
        let sanitizer = PdfSanitizer(document)
        _ = try sanitizer.scan()
        XCTAssertFalse(try OptimizeKit.everywhere(try sanitizer.run(SanitizeOptions()).bytes, "MARKERJS1"))
    }

    func test_anActionWithoutAKnownTypeStillHasItsChainFiltered() throws {
        for action in ["<</Next 8 0 R>>", "<</S /GoToDp /Next 8 0 R>>"] {
            let result = try run(file("/OpenAction 5 0 R", "", [(5, action), (8, "<</S /JavaScript /JS (MARKERJS1)>>")]))
            XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERJS1"), action)
            XCTAssertEqual(1, SanitizeKit.count(result.removed, .javaScript), action)
        }
    }

    func test_aLinkPartialActionIsFiltered() throws {
        let result = try run(file("", "/Annots [5 0 R]", [(5, "<</Type /Annot /Subtype /Link /Rect [0 0 9 9] /PA <</S /URI /URI (http://MARKERURL.example/)>>>>")]))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERURL"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .externalLinks))
    }

    func test_aRenditionThatRunsAScriptCountsAsJavaScript() throws {
        let source = file("/OpenAction 5 0 R", "", [(5, "<</S /Rendition /OP 0 /JS (MARKERJS1)>>")])
        let bothOff = try run(source, SanitizeOptions(javaScript: false, launchActions: false))
        XCTAssertTrue(try OptimizeKit.everywhere(bothOff.bytes, "MARKERJS1"))
        let scriptsOff = try run(source, SanitizeOptions(javaScript: false))
        XCTAssertFalse(try OptimizeKit.everywhere(scriptsOff.bytes, "MARKERJS1"))
        XCTAssertEqual(1, SanitizeKit.count(scriptsOff.removed, .launchActions))
        let launchOff = try run(source, SanitizeOptions(launchActions: false))
        XCTAssertFalse(try OptimizeKit.everywhere(launchOff.bytes, "MARKERJS1"))
        XCTAssertEqual(1, SanitizeKit.count(launchOff.removed, .javaScript))
    }

    func test_namedAndTemplatePagesGoWithTheScripts() throws {
        for tree in ["Templates", "Pages"] {
            let pdf = TestPdf()
            pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Names <</\(tree) <</Names [(t) 6 0 R]>>>>>>")
            pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
            pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
            pdf.obj(6, "<</Type /Page /Parent 2 0 R /Contents 7 0 R>>")
            pdf.stream(7, "", "BT (MARKERHIDDENPAGE) Tj ET")
            let result = try run(pdf.finish())
            XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERHIDDENPAGE"), tree)
            XCTAssertEqual(1, SanitizeKit.count(result.removed, .javaScript), tree)
            XCTAssertEqual(1, try PdfDocument.open(result.bytes).pages.count, tree)
        }
    }

    func test_alternatePresentationsGoWithTheScripts() throws {
        let result = try run(file("/Names <</AlternatePresentations <</Names [(s) 6 0 R]>>>>", "",
                                  [(6, "<</Type /SlideShow /Subtype /Embedded /Resources <</Names [(MARKERSLIDE) 3 0 R]>>>>")]))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERSLIDE"))
    }

    func test_aThreeDimensionalScriptGoesWithTheScripts() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [5 0 R]>>")
        pdf.obj(5, "<</Type /Annot /Subtype /3D /Rect [0 0 50 50] /3DD 6 0 R>>")
        pdf.stream(6, "/Type /3D /Subtype /U3D /OnInstantiate 7 0 R", "U3D")
        pdf.stream(7, "", "app.alert('MARKERJS1')")
        let result = try run(pdf.finish())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERJS1"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .javaScript))
    }

    func test_relatedFilesGoWithTheEmbeddedFile() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction <</S /GoToR /F 5 0 R /D [0 /Fit]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(5, "<</Type /Filespec /F (a.txt) /EF <</F 6 0 R>> /RF <</F 8 0 R>>>>")
        pdf.stream(6, "/Type /EmbeddedFile", "MARKERATTACH")
        pdf.obj(8, "[(a.txt) 9 0 R]")
        pdf.stream(9, "/Type /EmbeddedFile", "MARKERRELATED")
        let result = try run(pdf.finish(), SanitizeOptions(launchActions: false))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERATTACH"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERRELATED"))
    }

    func test_filePathsInIndirectStringsAndLaunchWindowsAreCut() throws {
        let source = file("/OpenAction 5 0 R", "/Annots [7 0 R]", [
            (5, "<</S /Launch /Win <</F (C:\\\\Users\\\\MARKERNAME\\\\run.exe) /D (C:\\\\Users\\\\MARKERDIR) /P (-x)>>>>"),
            (6, "(C:\\\\Users\\\\MARKERINDIRECT\\\\a.txt)"),
            (7, "<</Type /Annot /Subtype /FileAttachment /Rect [0 0 9 9] /FS <</Type /Filespec /F 6 0 R /UF 6 0 R>>>>"),
        ])
        let result = try run(source, SanitizeOptions(launchActions: false, embeddedFiles: false))
        for leak in ["MARKERNAME", "MARKERDIR", "MARKERINDIRECT"] { XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, leak), leak) }
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "run.exe"))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "a.txt"))
    }

    func test_aLaunchParameterStringIsDropped() throws {
        let source = file("/OpenAction 5 0 R", "", [(5, "<</S /Launch /Win <</F (cmd.exe) /P (/c C:\\Users\\MARKERNAME\\run.bat)>>>>")])
        let result = try run(source, SanitizeOptions(launchActions: false))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERNAME"))
        XCTAssertEqual(1, SanitizeKit.count(result.removed, .filePaths))
    }

    func test_aSubmitAddressIsNotAFilePath() throws {
        let address = "https://forms.example/app/x/post"
        let source = file("/OpenAction 5 0 R", "", [(5, "<</S /SubmitForm /F <</FS /URL /F (\(address))>>>>")])
        let result = try run(source, SanitizeOptions(launchActions: false))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, address))
        XCTAssertEqual(0, SanitizeKit.count(result.removed, .filePaths))
    }

    func test_anOpiFileNameIsCutToTheFileName() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</XObject <</Im0 5 0 R>>>> /Contents 6 0 R>>")
        pdf.stream(5, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /OPI <</2.0 <</Type /OPI /Version 2.0 /F (/home/MARKERUSER/pic.tif)>>>>", "H")
        pdf.stream(6, "", "q 10 0 0 10 0 0 cm /Im0 Do Q")
        let result = try run(pdf.finish())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERUSER"))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "pic.tif"))
    }
}
