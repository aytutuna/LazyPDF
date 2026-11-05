import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/ViewerSettingsTests.cs: the same cases.

final class ViewerSettingsTests: XCTestCase {
    func test_defaultsWhenTheCatalogSaysNothing() throws {
        let settings = ViewerSettings.read(try StructureFixtures.open())
        XCTAssertEqual(settings, ViewerSettings(nil, false, .useNone, .singlePage, false, false, false, false, false, false, false, nil, nil))
    }

    func test_readsEverything() throws {
        let document = try StructureFixtures.file(
            "/Lang (tr-TR) /PageMode /UseOutlines /PageLayout /TwoPageRight /ViewerPreferences <</DisplayDocTitle true /HideToolbar true /FitWindow true " +
            "/Direction /R2L /PrintScaling /None /Duplex /DuplexFlipLongEdge /NumCopies 3 /HideMenubar false>>")
        let settings = ViewerSettings.read(document)
        XCTAssertEqual(settings.language, "tr-TR")
        XCTAssertEqual(settings.pageMode, .useOutlines)
        XCTAssertEqual(settings.pageLayout, .twoPageRight)
        XCTAssertTrue(settings.displayDocTitle && settings.hideToolbar && settings.fitWindow && settings.rightToLeft && settings.printScalingNone)
        XCTAssertFalse(settings.hideMenubar || settings.centerWindow || settings.hideWindowUI)
        XCTAssertEqual(settings.duplex, "DuplexFlipLongEdge")
        XCTAssertEqual(settings.numCopies, 3)
    }

    func test_unknownValuesFallBack() throws {
        let document = try StructureFixtures.file("/PageMode /Bogus /PageLayout 5 /ViewerPreferences <</NumCopies 99 /Direction /Sideways>>")
        let settings = ViewerSettings.read(document)
        XCTAssertEqual(settings.pageMode, .useNone)
        XCTAssertEqual(settings.pageLayout, .singlePage)
        XCTAssertNil(settings.numCopies)
        XCTAssertFalse(settings.rightToLeft)
    }

    func test_writesAndReadsBack() throws {
        let document = try StructureFixtures.open()
        let wanted = ViewerSettings("en-US", true, .fullScreen, .oneColumn, true, true, true, true, true, true, true, "Simplex", 2)
        wanted.write(document)
        let reopened = try StructureFixtures.reopen(document)
        XCTAssertEqual(ViewerSettings.read(reopened), wanted)
    }

    func test_defaultsAreTakenOutNotWritten() throws {
        let document = try StructureFixtures.file("/PageMode /UseThumbs /Lang (de) /ViewerPreferences <</DisplayDocTitle true /Enforce [/PrintScaling] /ViewArea /CropBox>>")
        var read = ViewerSettings.read(document)
        read.displayDocTitle = false
        read.pageMode = .useNone
        read.language = nil
        read.write(document)
        XCTAssertNil(document.catalog["PageMode"])
        XCTAssertNil(document.catalog["Lang"])
        let prefs = try XCTUnwrap(document.dict(document.catalog, "ViewerPreferences"))
        XCTAssertNil(prefs["DisplayDocTitle"])
        XCTAssertNotNil(prefs["Enforce"])
        XCTAssertNotNil(prefs["ViewArea"])
    }

    func test_emptyPreferencesAreDropped() throws {
        let document = try StructureFixtures.file("/ViewerPreferences <</HideToolbar true>>")
        var read = ViewerSettings.read(document)
        read.hideToolbar = false
        read.write(document)
        XCTAssertNil(document.catalog["ViewerPreferences"])
    }

    func test_languageWithNonAsciiIsAString() throws {
        let document = try StructureFixtures.open()
        var read = ViewerSettings.read(document)
        read.language = "tr"
        read.write(document)
        XCTAssertTrue(document.catalog["Lang"] is PdfString)
    }

    func test_indirectPreferencesAreChangedInPlace() throws {
        let document = try StructureFixtures.file("/ViewerPreferences 30 0 R", { pdf in pdf.obj(30, "<</CenterWindow true>>") })
        var read = ViewerSettings.read(document)
        read.hideMenubar = true
        read.write(document)
        let prefs = try XCTUnwrap(document.get(30) as? PdfDictionary)
        XCTAssertNotNil(prefs["HideMenubar"])
        XCTAssertNotNil(prefs["CenterWindow"])
        XCTAssertTrue(document.catalog["ViewerPreferences"] is PdfReference)
    }

    // The C# parses the mode with Enum.TryParse, which takes a number or a list; only the names read here.
    func test_aNumberOrAListIsNotAPageMode() throws {
        let document = try StructureFixtures.file("/PageMode /1 /PageLayout /OneColumn,TwoColumnLeft")
        let settings = ViewerSettings.read(document)
        XCTAssertEqual(settings.pageMode, .useNone)
        XCTAssertEqual(settings.pageLayout, .singlePage)
    }
}
