import XCTest
@testable import LazyPDFApp

// Mirrors AppInfoTests in windows/LazyPDF.App.Tests/PackagingTests.cs. The Windows version test reads the build props; here
// the version is the bundle's, so the test gives it a bundle's dictionary.

final class AppInfoTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func test_theVersionIsTheOneOfTheBundle() {
        XCTAssertEqual(AppInfo.bundleVersion(["CFBundleShortVersionString": "1.2.3"]), "1.2.3")
        XCTAssertEqual(AppInfo.bundleVersion([:]), "0.0.0")
        XCTAssertEqual(AppInfo.bundleVersion(nil), "0.0.0")
    }

    func test_theCopyrightIsTheLicenceLine() {
        XCTAssertEqual(AppInfo.copyright, "Copyright (c) 2026 Aytu Tuna")
    }

    func test_theLicenceIsNamed() {
        XCTAssertEqual(AppInfo.licence, "PolyForm Noncommercial 1.0.0")
    }

    func test_theNoticesFileIsTheOneOfTheRepository() throws {
        let notices = try XCTUnwrap(AppInfo.notices(in: repository))

        XCTAssertTrue(notices.contains("Lazy PDF third-party notices"))
        XCTAssertFalse(notices.contains("Not established"))
        XCTAssertTrue(notices.contains("Redistribution and use in source and binary forms"))
        XCTAssertTrue(notices.contains("AFM files"))
    }

    func test_aMissingNoticesFileReadsAsNil() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertNil(AppInfo.notices(in: nowhere))
    }
}
