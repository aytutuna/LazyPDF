import XCTest
@testable import LazyPDFApp

// The language list Ocr and Batch share (windows/LazyPDF.App/Tools/Ocr/OcrLanguages.cs). The system's list is faked.

final class OcrLanguagesTests: XCTestCase {
    func test_theLanguagesAreListedByName() {
        let state = OcrLanguageState.make(supported: ["tr-TR", "en-US", "de-DE"], wanted: [])

        XCTAssertEqual(state.installed.map(\.tag).sorted(), ["de-DE", "en-US", "tr-TR"])
        XCTAssertEqual(state.installed.map(\.name), state.installed.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func test_aWantedLanguageThatMatchesBySubtagIsNotMissing() {
        let state = OcrLanguageState.make(supported: ["tr-TR", "en-US"], wanted: ["tr", "en-GB", "fr-CA"])

        XCTAssertEqual(state.missing.count, 1)
    }

    func test_aLanguageWantedTwiceIsMissingOnce() {
        let state = OcrLanguageState.make(supported: ["en-US"], wanted: ["fr-CA", "fr-FR", "fr"])

        XCTAssertEqual(state.missing.count, 1)
    }

    func test_theListStartsOnTheAppsLanguageThenEnglishThenTheFirst() {
        let state = OcrLanguageState.make(supported: ["de-DE", "en-US", "tr-TR"], wanted: [])

        XCTAssertEqual(state.preferred(own: "tr")?.tag, "tr-TR")
        XCTAssertEqual(state.preferred(own: "fr")?.tag, "en-US")
        XCTAssertNotNil(OcrLanguageState.make(supported: ["de-DE"], wanted: []).preferred(own: "fr"))
        XCTAssertNil(OcrLanguageState.make(supported: [], wanted: []).preferred(own: "en"))
    }

    func test_adviceSaysOnlyWhatIsMissing() {
        XCTAssertEqual(OcrLanguageState.make(supported: ["en-US"], wanted: ["en"]).advice, "")
        XCTAssertTrue(OcrLanguageState.make(supported: ["en-US"], wanted: ["fr"]).advice.hasPrefix("No text recognition for"))
        XCTAssertFalse(OcrLanguageState.make(supported: [], wanted: []).advice.isEmpty)
    }
}
