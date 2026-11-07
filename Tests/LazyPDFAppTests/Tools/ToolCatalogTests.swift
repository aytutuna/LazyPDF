import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/ToolCatalogTests.cs: every tool in a group, each with a title and a symbol.

final class ToolCatalogTests: XCTestCase {
    private let expected = [
        "comment", "editcontent", "pages", "combine", "stamps", "forms", "fillsign", "certificates", "protect", "redact",
        "optimize", "sanitize", "compare", "export", "create", "ocr", "accessibility", "standards", "measure", "batch", "metadata",
    ]

    func test_everyToolOfTheShellIsListed() {
        XCTAssertEqual(ToolCatalog.tools.map(\.id).sorted(), expected.sorted())
    }

    func test_idsAreUniqueAndLowerCase() {
        let ids = ToolCatalog.tools.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids { XCTAssertEqual(id, id.lowercased()) }
    }

    func test_everyToolHasWordsAndASymbol() {
        for tool in ToolCatalog.tools {
            XCTAssertFalse(tool.title.isEmpty, tool.id)
            XCTAssertFalse(tool.summary.isEmpty, tool.id)
            XCTAssertFalse(tool.symbol.isEmpty, tool.id)
        }
        for panel in ToolCatalog.sidePanels {
            XCTAssertFalse(panel.title.isEmpty, panel.id)
            XCTAssertFalse(panel.summary.isEmpty, panel.id)
            XCTAssertFalse(panel.symbol.isEmpty, panel.id)
        }
    }

    func test_everyGroupOfTheStripHasATool() {
        for group in ToolGroup.allCases {
            XCTAssertTrue(ToolCatalog.tools.contains { $0.group == group }, "\(group)")
            XCTAssertFalse(ToolCatalog.groupTitle(group).isEmpty)
            XCTAssertFalse(ToolCatalog.groupSymbol(group).isEmpty)
        }
    }

    func test_theGroupsAreTheOnesOfTheStrip() {
        XCTAssertEqual(ToolGroup.allCases.map(ToolCatalog.groupTitle),
                       ["Comment", "Edit", "Pages", "Forms", "Sign", "Protect", "Convert", "Scan and OCR", "Compare", "Accessibility"])
    }

    func test_theRailHasTheSevenSidePanels() {
        XCTAssertEqual(ToolCatalog.sidePanels.map(\.id),
                       ["pages", "bookmarks", "attachments", "layers", "comments", "signatures", "search"])
    }

    func test_toolsAndSidePanelsAreFoundById() {
        XCTAssertEqual(ToolCatalog.find("combine")?.title, "Combine files")
        XCTAssertEqual(ToolCatalog.findSide("bookmarks")?.title, "Bookmarks")
        XCTAssertNil(ToolCatalog.find("nothing"))
        XCTAssertNil(ToolCatalog.findSide("nothing"))
    }
}
