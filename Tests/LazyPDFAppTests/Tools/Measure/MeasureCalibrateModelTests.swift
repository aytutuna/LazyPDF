import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The calibrate flow of the Measure model: a line of a known length sets the scale of the page it is on.
// Mirrors the calibration tests of windows/LazyPDF.App.Tests/Tools/measure/MeasureToolTests.cs.

@MainActor
final class MeasureCalibrateModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]? = nil) throws -> (model: MeasureModel, rig: ToolRig) {
        let rig = try ToolRig(bytes ?? Pdfs.text(3))
        let model = MeasureModel(fonts: FakeFonts())
        model.author = "Sam"
        rig.attach(model)
        return (model, rig)
    }

    // A line of 72 points, 25.4 mm on the page.
    private func draw(_ model: MeasureModel, page: Int = 0) throws {
        let tool = try XCTUnwrap(model.tool)
        for x in [0.0, 72] {
            tool.press(PagePointer(page: page, point: ViewPoint(x, 0), view: ViewPoint(x, 0), pressed: true, clicks: 1))
        }
    }

    private func calibrate(_ model: MeasureModel, _ length: String, page: Int = 0) throws {
        model.startCalibrate()
        try draw(model, page: page)
        model.setCalibrateValue(length)
        model.setCalibrateUnit(.metre)
        model.applyCalibration()
    }

    func test_aLineOfKnownLengthSetsTheScaleOfItsPageOnly() async throws {
        let (model, rig) = try attached()
        rig.viewer.pageIndex = 1
        await waitUntil { model.shownPage == 1 }

        try calibrate(model, "10", page: 1)

        let document = rig.tab.document
        XCTAssertFalse(model.calibrating)
        XCTAssertEqual(model.scales.scale(document, 0), .actual)
        XCTAssertEqual(model.scales.scale(document, 2), .actual)
        XCTAssertEqual(MeasureItem(.distance, 1, [ViewPoint(0, 0), ViewPoint(72, 0)]).value(model.scales.scale(document, 1)), "10 m")
        XCTAssertEqual(model.realValue, "0.393701")
        XCTAssertEqual(model.realUnit, .metre)
        XCTAssertEqual(model.pageValue, "1")
        XCTAssertTrue(model.action?.canRun() == false)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func test_theDrawnLengthIsShownAtTheScaleOfThePageAndTheLineIsNoRow() async throws {
        let (model, _) = try attached()
        model.startCalibrate()
        XCTAssertEqual(model.hint, "Click the two ends of something whose real length you know.")
        XCTAssertNil(model.calibrateDrawn)

        try draw(model)

        XCTAssertEqual(model.calibrateDrawn, "Line drawn: 25.4 mm")
        XCTAssertTrue(model.calibrating)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.calibrateUnit, .millimetre)
    }

    func test_aTouchPanelAsksForTapsNotClicks() async throws {
        let rig = try ToolRig(Pdfs.text(1))
        let model = MeasureModel(fonts: FakeFonts(), touch: true)
        rig.attach(model)

        model.startCalibrate()

        XCTAssertTrue(model.hint.hasPrefix("Tap the two ends of something whose real length you know."))
    }

    func test_calibratingForcesDistanceAndArmsThePointer() async throws {
        let (model, rig) = try attached()
        model.pick(.area)
        rig.viewer.pointerTool = nil
        await waitUntil { model.kind == nil }

        model.startCalibrate()

        XCTAssertEqual(model.kind, .distance)
        XCTAssertTrue(rig.viewer.pointerTool is MeasureTool)
        XCTAssertEqual(model.tool?.kind, .distance)
    }

    func test_aZeroTextOrTooSmallALengthIsRefusedAndTheScaleStays() async throws {
        let (model, rig) = try attached()
        for bad in ["0", "abc", "", "-3", "0.000000000000000000000001"] {
            try calibrate(model, bad)

            XCTAssertTrue(model.calibrateProblem, bad)
            XCTAssertTrue(model.calibrating, bad)
            XCTAssertEqual(model.scales.scale(rig.tab.document, 0), .actual, bad)
            model.cancelCalibrate()
        }
    }

    func test_cancelEndsTheFlowAndChangesNothing() async throws {
        let (model, rig) = try attached()
        model.startCalibrate()
        try draw(model)

        model.cancelCalibrate()

        XCTAssertFalse(model.calibrating)
        XCTAssertNil(model.calibrateDrawn)
        XCTAssertEqual(model.scales.scale(rig.tab.document, 0), .actual)
        XCTAssertEqual(model.hint, "Click the two ends. Hold Shift for straight lines.")
        XCTAssertFalse(try XCTUnwrap(model.tool).calibrate)
    }

    func test_theHandButtonPickingAKindAndDetachingEndTheFlow() async throws {
        let (model, rig) = try attached()
        model.startCalibrate()
        rig.viewer.pointerTool = nil
        await waitUntil { !model.calibrating }
        XCTAssertNil(model.kind)

        model.startCalibrate()
        model.pick(.perimeter)
        XCTAssertFalse(model.calibrating)
        XCTAssertFalse(try XCTUnwrap(model.tool).calibrate)

        model.startCalibrate()
        model.detach()
        XCTAssertFalse(model.calibrating)
    }

    func test_aChangeOfTheFileEndsTheFlowBeforeSetScaleCanLandOnAReusedPage() async throws {
        let (model, rig) = try attached()
        model.startCalibrate()
        try draw(model)

        try PageOperations.delete(rig.tab.document, [0])
        XCTAssertTrue(try rig.tab.commit("Delete"))
        await waitUntil { !model.calibrating }
        model.setCalibrateValue("10")
        model.applyCalibration()

        XCTAssertNil(model.calibrateDrawn)
        XCTAssertTrue((0..<rig.tab.document.pages.count).allSatisfy { model.scales.scale(rig.tab.document, $0) == .actual })
    }

    func test_setScaleDoesNothingWhenThePageIsGoneOrAnotherTabIsShown() async throws {
        let (model, rig) = try attached()
        model.startCalibrate()
        try draw(model, page: 2)
        model.setCalibrateValue("10")

        try PageOperations.delete(rig.tab.document, [2])
        model.applyCalibration()
        rig.viewer.show(nil)
        model.applyCalibration()

        XCTAssertTrue(model.calibrating)
        XCTAssertTrue((0..<2).allSatisfy { model.scales.scale(rig.tab.document, $0) == .actual })
    }
}
