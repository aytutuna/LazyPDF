import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/stamps/StampsPanelTests.cs: the model as the window drives it: the form, the list of
// runs, the pages' preview and the action. The form is changed through `edit`, which stands for the control's change event.

@MainActor
final class StampsModelTests: XCTestCase {
    private func attach(_ bytes: [UInt8]? = nil, password: String? = nil) throws -> (model: StampsModel, rig: ContentRig) {
        let rig = try ContentRig(bytes ?? Pdfs.text(3), password: password)
        let model = StampsModel()
        rig.attach(model)
        return (model, rig)
    }

    private func stamps(_ tab: DocumentTab) -> [StampInfo] {
        PdfStamper(tab.document).list()
    }

    private func previews(_ rig: ContentRig) -> [OverlayItem] {
        rig.viewer.overlay(0).items.filter { $0.id.hasPrefix(StampPreview.prefix) }
    }

    // The stamps write their text as hex strings.
    private func shows(_ tab: DocumentTab, _ page: Int, _ text: String) -> Bool {
        let hex = text.utf8.map { String(format: "%02X", $0) }.joined()
        let content = String(tab.document.pages[page].contents().map { Character(UnicodeScalar($0)) })
        return content.contains(hex)
    }

    private func withWatermark() throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text(3))
        try PdfStamper(session.document).addWatermark(WatermarkSpec(text: "DRAFT"))
        try session.commit("Add watermark")
        return session.current
    }

    func test_closingThePanelWithARunSelectedLeavesNothingOnThePages() async throws {
        let (model, rig) = try attach(try withWatermark())
        model.select(model.runs[0])
        model.edit { $0.watermarkText = "OTHER" }
        XCTAssertFalse(previews(rig).isEmpty)

        model.detach()

        XCTAssertTrue(previews(rig).isEmpty)
    }

    func test_aPickedRunIsNotPreviewedUntilTheFormChanges() async throws {
        let (model, rig) = try attach(try withWatermark())

        model.select(model.runs[0])
        XCTAssertTrue(previews(rig).isEmpty)
        XCTAssertEqual(model.action?.canRun(), false)

        model.edit { $0.watermarkText = "DRAFT 2" }
        XCTAssertFalse(previews(rig).isEmpty)
        XCTAssertEqual(model.action?.canRun(), true)
    }

    func test_removingAStampAlsoTakesItsPreviewOff() async throws {
        let (model, rig) = try attach(try withWatermark())
        model.select(model.runs[0])
        model.edit { $0.watermarkText = "DRAFT 2" }

        await model.removeSelected()

        XCTAssertTrue(previews(rig).isEmpty)
        XCTAssertEqual(rig.host.status, "Stamp removed.")
        XCTAssertTrue(stamps(rig.tab).isEmpty)
        XCTAssertTrue(model.runs.isEmpty)
    }

    func test_updatingABatesRunKeepsItsNumbers() async throws {
        let (model, rig) = try attach()
        model.setMode(.bates)
        model.edit { $0.prefix = "ACME-"; $0.start = "5" }

        await model.action?.run()

        XCTAssertEqual(model.form.start, "8")
        XCTAssertTrue(previews(rig).isEmpty)
        let run = try XCTUnwrap(stamps(rig.tab).first)
        XCTAssertEqual(stamps(rig.tab).count, 1)

        model.select(model.runs[0])
        XCTAssertEqual(model.form.start, "5")
        model.edit { $0.suffix = "-X" }
        await model.action?.run()

        XCTAssertEqual(model.form.start, "5")
        XCTAssertEqual(stamps(rig.tab).map(\.id), [run.id])
        XCTAssertTrue(shows(rig.tab, 0, "ACME-000005-X"))
        XCTAssertTrue(shows(rig.tab, 2, "ACME-000007-X"))
    }

    func test_aWrittenRunComesBackIntoTheFormWhole() async throws {
        let (model, rig) = try attach()
        model.edit {
            $0.watermarkText = "Line one\nLine two that is long enough to pass the label limit of the file by quite some way"
            $0.turn = 30
        }
        await model.action?.run()
        XCTAssertEqual(stamps(rig.tab).count, 1)

        model.select(model.runs[0])

        XCTAssertTrue(model.form.watermarkText.hasPrefix("Line one\nLine two"))
        XCTAssertEqual(model.form.turn, 30)
    }

    func test_aRunReadFromAFileAsksForWhatTheFileDoesNotKeep() async throws {
        let session = try PdfEditSession.open(Pdfs.text(3))
        try PdfStamper(session.document, FakeFonts()).addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("ACME")))
        try session.commit("Add header and footer")
        let (model, _) = try attach(session.current)

        model.select(model.runs[0])
        model.edit { $0.italic = true }

        XCTAssertEqual(model.action?.canRun(), false)
        XCTAssertFalse(model.problem?.isEmpty ?? true)
    }

    func test_aFileThatForbidsChangesIsLeftAlone() async throws {
        let (model, rig) = try attach(try Pdfs.restricted(PdfPermissions.all.subtracting(.modify)), password: "")

        await model.action?.run()

        XCTAssertEqual(rig.host.problems.first?.title, "This file cannot be changed")
        XCTAssertTrue(stamps(rig.tab).isEmpty)
        XCTAssertFalse(rig.tab.session.canUndo)
    }

    func test_aSignedFileAsksBeforeItIsStamped() async throws {
        let (model, rig) = try attach(try Pdfs.signed(certified: false))

        await model.action?.run()
        XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"])
        XCTAssertTrue(stamps(rig.tab).isEmpty)

        rig.host.notices[0].action?.run()
        await waitUntil { stamps(rig.tab).count == 1 }
    }

    func test_removingFromASignedFileAsksFirstToo() async throws {
        let (model, rig) = try attach(try Pdfs.signed(certified: true))
        try PdfStamper(rig.tab.document).addWatermark(WatermarkSpec(text: "DRAFT"))

        await model.removeAll()

        XCTAssertEqual(rig.host.notices.count, 1)
        XCTAssertEqual(stamps(rig.tab).count, 1)
    }

    func test_aCancelledRunLeavesTheDocumentAsItWas() async throws {
        let (model, rig) = try attach()
        rig.host.cancelled = true

        await model.action?.run()

        XCTAssertTrue(stamps(rig.tab).isEmpty)
        XCTAssertFalse(rig.tab.session.canUndo)
        XCTAssertEqual(rig.host.status, "Canceled.")
        XCTAssertFalse(rig.tab.session.isDirty)
        XCTAssertFalse(model.isBusy)
    }

    func test_anUndoDuringTheRunDoesNotReportAStamp() async throws {
        let (model, rig) = try attach()
        try Pdfs.retitle(rig.tab.session, "A")
        try rig.tab.commit("Properties")
        let tab = rig.tab
        rig.host.before = { _ = try? tab.undo() }

        await model.action?.run()

        XCTAssertTrue(stamps(rig.tab).isEmpty)
        XCTAssertFalse(rig.host.statuses.contains { $0.contains("Stamped") })
    }

    func test_aPageRangeThatMatchesNothingStopsTheStamp() async throws {
        let (model, _) = try attach()

        model.edit { $0.pages = .typed; $0.pagesText = "9" }

        XCTAssertNotNil(model.problem)
        XCTAssertEqual(model.action?.canRun(), false)
    }

    func test_whatWasTypedComesBackWhenThePanelIsShownAgain() async throws {
        let (model, rig) = try attach()
        model.edit { $0.watermarkText = "KEPT" }

        model.detach()
        rig.attach(model)

        XCTAssertEqual(model.form.watermarkText, "KEPT")
    }

    func test_aPictureWatermarkIsPickedThroughTheFilePicker() async throws {
        let (model, rig) = try attach()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("logo.png")
        try Data([1, 2, 3]).write(to: file)
        rig.host.picked = [ToolFile(url: file)]
        model.edit { $0.watermarkText = "" }

        await model.pickPicture()
        XCTAssertEqual(model.pictureName, "logo.png")
        XCTAssertNil(model.problem)
        await model.action?.run()

        XCTAssertEqual(stamps(rig.tab).map(\.label), ["image"])
    }

    // Decodes any file as a 4 by 2 picture, as a codec that ignores the Exif turn does.
    private final class WideCodec: ImageCodec {
        func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
        func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { [PdfRgbaImage(4, 2, [UInt8](repeating: 128, count: 4 * 2 * 4))] }
        func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
    }

    func test_aTurnedPictureIsPreviewedUprightAsItIsStamped() async throws {
        let (model, rig) = try attach()
        rig.host.imageCodec = WideCodec()
        let turned: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0, 34] + Array("Exif".utf8) + [0, 0] + Array("MM".utf8)
            + [0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0]

        model.setPicture(turned)

        XCTAssertEqual([model.pictureImage?.width, model.pictureImage?.height], [2, 4])
    }

    func test_thePreviewFollowsThePageInView() async throws {
        let (model, rig) = try attach()
        XCTAssertEqual(previews(rig).count, 1)

        model.edit { $0.pages = .typed; $0.pagesText = "2" }

        XCTAssertTrue(previews(rig).isEmpty)
    }

    func test_aBatesPreviewStartsAtTheNumberTyped() async throws {
        let (model, rig) = try attach()

        model.setMode(.bates)
        model.edit { $0.prefix = "N-"; $0.start = "7"; $0.digits = "2" }

        let items = previews(rig)
        XCTAssertEqual(items.count, 1)
        guard case .text(let shown) = items[0].shape else { return XCTFail("The mark should be a text.") }
        XCTAssertEqual(shown.text, "N-07")
    }
}
