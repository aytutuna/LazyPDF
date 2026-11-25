import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/ImageLookTests.cs: the same cases.

final class ImageLookTests: XCTestCase {
    private func alike(_ first: String, _ second: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try CompareReviewTests.picture(first)
        let b = try CompareReviewTests.picture(second)
        XCTAssertTrue(try PdfComparer.compare(a, b).isIdentical, file: file, line: line)
    }

    private func apart(_ first: String, _ second: String, _ extra: ((TestPdf, Int) -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try CompareReviewTests.picture(first, extra)
        let b = try CompareReviewTests.picture(second, extra)
        let change = try CompareKit.single(try PdfComparer.compare(a, b).changes, file: file, line: line)
        XCTAssertEqual(change.detail, CompareText.imageReplaced, file: file, line: line)
    }

    func test_oneFilterInAnArrayReadsLikeABareFilter() throws {
        try alike("/Filter [/FlateDecode] /DecodeParms [<</Predictor 15 /Columns 100>>]", "/Filter /FlateDecode /DecodeParms <</Predictor 15 /Columns 100>>")
        try alike("/Filter [/ASCIIHexDecode] /DecodeParms [null]", "")
        try alike("/Filter /AHx", "")
    }

    func test_valuesSpelledOutAsTheirDefaultsAreLeftOut() throws {
        try alike("/DecodeParms [null]", "")
        try alike("/DecodeParms <</Predictor 1 /Colors 1>>", "")
        try alike("/ImageMask false", "")
        try alike("/Decode [0 1]", "")
        try alike("/ColorSpace [/Indexed /DeviceGray 1 <00FF>] /Decode [0 255]", "/ColorSpace [/Indexed /DeviceGray 1 <00FF>]")
    }

    func test_howTheStoredBytesAreReadIsPartOfTheLook() throws {
        try apart("/BitsPerComponent 4", "")
        try apart("/Filter /RunLengthDecode", "")
        try apart("/Decode [0 255]", "")
    }

    func test_entriesOfAMaskThatGovernItsSamplesAreSeen() throws {
        func mask(_ width: Int, _ height: Int) -> String {
            "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode"
        }
        let samples = "00FF00FF00FF00FF>"
        let wide = try CompareReviewTests.picture("/SMask 10 0 R", { pdf, _ in pdf.stream(10, mask(4, 2), samples) })
        let tall = try CompareReviewTests.picture("/SMask 10 0 R", { pdf, _ in pdf.stream(10, mask(2, 4), samples) })
        let again = try CompareReviewTests.picture("/SMask 10 0 R", { pdf, _ in pdf.stream(10, mask(4, 2), samples) })
        XCTAssertEqual(try CompareKit.single(try PdfComparer.compare(wide, tall).changes).detail, CompareText.imageReplaced)
        XCTAssertTrue(try PdfComparer.compare(wide, again).isIdentical)
    }

    func test_rangeOfASampledTintFunctionIsSeen() throws {
        func function(_ range: String) -> (TestPdf, Int) -> Void {
            { pdf, _ in pdf.stream(10, "/FunctionType 0 /Domain [0 1] /Range \(range) /Size [2] /BitsPerSample 8", "AB") }
        }
        let space = "/ColorSpace [/Separation /Spot /DeviceGray 10 0 R]"
        let full = try CompareReviewTests.picture(space, function("[0 1]"))
        let half = try CompareReviewTests.picture(space, function("[0 0.5]"))
        let respelled = try CompareReviewTests.picture(space, function("[0.0 1.0]"))
        XCTAssertEqual(try CompareKit.single(try PdfComparer.compare(full, half).changes).detail, CompareText.imageReplaced)
        XCTAssertTrue(try PdfComparer.compare(full, respelled).isIdentical)
    }

    func test_numbersAreSpelledAsRoundTripUpToTheSeventeenthPlace() throws {
        let document = try CompareReviewTests.picture("")
        let image = PdfDictionary()
        image["Matte"] = PdfArray([PdfNumber(1_000_000_000_000_000), PdfNumber(10_000_000_000_000_000), PdfNumber(100_000_000_000_000_000), PdfNumber(0.00001)])
        XCTAssertTrue(try ImageLook(document).of(image).contains("[1000000000000000 10000000000000000 1E+17 1E-05]"))
    }
}
