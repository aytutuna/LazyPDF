import XCTest
import UIKit
import LazyPDFIOS

@MainActor
final class SystemServiceTests: XCTestCase {
    func test_theSheetPrintsTheDocumentsBytesUnderItsName() throws {
        let pdf = try samplePdf()

        let item = IOSSystemPrint.item(pdf)
        let info = IOSSystemPrint.info(name: "Report.pdf")

        XCTAssertEqual([UInt8](item), pdf)
        XCTAssertTrue(UIPrintInteractionController.canPrint(item))
        XCTAssertEqual(info.jobName, "Report.pdf")
        XCTAssertEqual(info.outputType, .general)
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
