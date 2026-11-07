import XCTest
import UIKit
import LazyPDFKit
import LazyPDFIOS

@MainActor
final class SystemServiceTests: XCTestCase {
    func test_theSheetPrintsTheDocumentsBytesUnderItsName() throws {
        let pdf = try samplePdf()

        let item = try IOSSystemPrint.item(try PdfEditSession.open(pdf))
        let info = IOSSystemPrint.info(name: "Report.pdf")

        XCTAssertEqual([UInt8](item), pdf)
        XCTAssertTrue(UIPrintInteractionController.canPrint(item))
        XCTAssertEqual(info.jobName, "Report.pdf")
        XCTAssertEqual(info.outputType, .general)
    }

    func test_aFileLockedWithAPasswordIsPrintedUnlocked() throws {
        let id = [UInt8](repeating: 0, count: 16)
        let security = PdfSecurity.create(userPassword: "secret", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: id)
        let locked = try PdfDocument.open(samplePdf()).saveRewrite(PdfSaveOptions(security: security, documentId: id))
        let session = try PdfEditSession.open(locked, password: "secret")

        let item = try IOSSystemPrint.item(session)

        XCTAssertNil(try PdfDocument.open([UInt8](item)).security)
        XCTAssertEqual(try PdfDocument.open([UInt8](item)).pages.count, 1)
    }

    func test_lazyPrintIsNeverHandedAPath() {
        XCTAssertFalse(IOSSisterApps().tryPrint(URL(fileURLWithPath: "/tmp/a.pdf")))
    }

    func test_theOpenPickerOffersPdfsPicturesAndText() {
        let identifiers = Set(openableTypes.map(\.identifier))

        XCTAssertTrue(identifiers.isSuperset(of: ["com.adobe.pdf", "public.png", "public.jpeg", "public.plain-text"]))
    }

    func test_theInfoListNamesTheSisterAppsItAsks() throws {
        let schemes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])

        XCTAssertEqual(Set(schemes), ["lazyscan", "lazyprint"])
    }
}
