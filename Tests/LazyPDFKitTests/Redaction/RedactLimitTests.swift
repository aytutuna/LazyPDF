import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactLimitTests.cs: the same cases. Where the interpreter drops state without
// saying so, the scan cannot tell where things are, and the page becomes a picture.

final class RedactLimitTests: XCTestCase {
    private let text = "BT /F1 12 Tf 50 700 Td (ZQXQSECRET) Tj ET"
    private let mark = PdfRect(40, 690, 200, 720)
    private let moved = PdfRect(340, 990, 500, 1020)

    private var deepStack: String { String(repeating: "q ", count: 300) + "1 0 0 1 300 300 cm Q " + text }

    func test_pageThatOpensMoreThanTheStackHoldsIsRefused() throws {
        let document = try RedactionKit.page(deepStack)
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, moved)], "ZQXQSECRET")
    }

    func test_pathLongerThanTheInterpreterKeepsIsRefused() throws {
        let path = String(repeating: "0 0 1 1 re ", count: 200_001)
        let document = try RedactionKit.page(path + "60 700 m 200 700 l S")
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, mark)], "60 700")
    }

    func test_formThatOpensMoreThanTheStackHoldsGoesWholeWhenItMeetsAMark() throws {
        let document = try RedactionKit.page("/Fm1 Do", "/XObject <</Fm1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", self.deepStack)
        }
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, mark)], "ZQXQSECRET")
    }

    func test_verifyReportsAMarkedPageItCannotFollow() throws {
        let document = try RedactionKit.page(deepStack)
        let verification = PdfRedactor.verify(try document.saveRewrite(), [RedactionMark.fromRect(0, moved)], [])
        XCTAssertFalse(verification.isClean)
    }

    func test_showOperatorWithMoreOperandsThanTheParserKeepsIsRefused() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td " + String(repeating: "(a) ", count: 520) + "(iiiiZQXOPERAND) Tj ET")
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, mark)], "ZQXOPERAND")
    }

    func test_markedContentNestedDeeperThanTheInterpreterReportsIsRefused() throws {
        let content = String(repeating: "/X BMC ", count: 1030) + "/Span <</Alt (ZQXDESCR)>> BDC " + text + " EMC " + String(repeating: "EMC ", count: 1030)
        let document = try RedactionKit.page(content)
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, mark)], "ZQXQSECRET", "ZQXDESCR")
    }
}
