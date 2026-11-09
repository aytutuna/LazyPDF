import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// The Measure tool as the window drives it. Windows has no test of MeasurePanel; the cases are those its code handles: the
// pointer tool it hands the viewer, the scale, the list kept per tab, and the one undo step Add to page makes.

@MainActor
final class MeasureModelTests: XCTestCase {
    private func attached(_ bytes: [UInt8]? = nil) throws -> (model: MeasureModel, rig: ToolRig) {
        let rig = try ToolRig(bytes)
        let model = MeasureModel(fonts: FakeFonts())
        model.author = "Sam"
        rig.attach(model)
        return (model, rig)
    }

    private func measure(_ model: MeasureModel, _ from: ViewPoint, _ to: ViewPoint) throws {
        let tool = try XCTUnwrap(model.tool)
        tool.press(PagePointer(page: 0, point: from, view: from, pressed: true, clicks: 1))
        tool.press(PagePointer(page: 0, point: to, view: to, pressed: true, clicks: 1))
    }

    func test_theModelHandsTheViewerTheToolAndTakesItBackOnDetach() throws {
        let (model, rig) = try attached()

        XCTAssertTrue(rig.viewer.pointerTool is MeasureTool)
        XCTAssertEqual(model.kind, .distance)
        XCTAssertEqual(model.hint, "Click the two ends. Hold Shift for straight lines.")

        model.detach()
        XCTAssertNil(rig.viewer.pointerTool)
    }

    func test_pickingAKindChangesTheToolAndTheHint() throws {
        let (model, _) = try attached()

        model.pick(.area)

        XCTAssertEqual(model.tool?.kind, .area)
        XCTAssertEqual(model.hint, "Click each corner, then double-click to finish. Hold Shift for straight lines.")
    }

    func test_aFinishedMeasurementWaitsInTheListWithItsValueAndPlace() throws {
        let (model, rig) = try attached()
        XCTAssertFalse(try XCTUnwrap(model.action).canRun())

        try measure(model, ViewPoint(0, 0), ViewPoint(72, 0))

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows[0].value, "25.4 mm")
        XCTAssertEqual(model.rows[0].place, "Page 1")
        XCTAssertEqual(model.rows[0].removeName, "Remove Distance")
        XCTAssertEqual(model.rows[0].spoken, "Distance, 25.4 mm, Page 1")
        XCTAssertTrue(try XCTUnwrap(model.action).canRun())
        XCTAssertFalse(rig.tab.isDirty)
    }

    func test_aNewScaleChangesWhatTheListReads() throws {
        let (model, _) = try attached()
        try measure(model, ViewPoint(0, 0), ViewPoint(72, 0))

        model.setRealValue("10")
        model.setRealUnit(.metre)
        model.setPageUnit(.inch)

        XCTAssertFalse(model.scaleProblem)
        XCTAssertEqual(model.rows[0].value, "10 m")
    }

    func test_aScaleThatIsNotAboveZeroIsFlaggedAndKeepsTheLastGoodOne() throws {
        let (model, _) = try attached()
        try measure(model, ViewPoint(0, 0), ViewPoint(72, 0))

        model.setPageValue("0")
        XCTAssertTrue(model.scaleProblem)
        model.setPageValue("abc")
        XCTAssertTrue(model.scaleProblem)
        XCTAssertEqual(model.rows[0].value, "25.4 mm")

        model.setPageValue("2")
        XCTAssertFalse(model.scaleProblem)
        XCTAssertEqual(model.rows[0].value, "12.7 mm")
    }

    func test_removingARowTakesItOffTheList() throws {
        let (model, _) = try attached()
        try measure(model, ViewPoint(0, 0), ViewPoint(72, 0))
        try measure(model, ViewPoint(0, 10), ViewPoint(144, 10))

        model.remove(model.rows[0])

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows[0].value, "50.8 mm")
    }

    func test_addToPageWritesEveryMeasurementAsOneUndoStep() async throws {
        let (model, rig) = try attached()
        try measure(model, ViewPoint(100, 100), ViewPoint(172, 100))
        try measure(model, ViewPoint(100, 200), ViewPoint(172, 200))

        await model.action?.run()

        let marks = PdfAnnotations.read(rig.tab.document, rig.tab.document.pages[0])
        XCTAssertEqual(marks.filter { $0.type == .line }.count, 2)
        XCTAssertEqual(marks.filter { $0.type == .freeText }.count, 2)
        XCTAssertEqual(rig.tab.session.undoLabel, "Measure")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(rig.host.statuses, ["Added 2 measurements"])
        XCTAssertTrue(try rig.tab.undo())
        XCTAssertTrue(PdfAnnotations.read(rig.tab.document, rig.tab.document.pages[0]).isEmpty)
    }

    func test_addToPageOfAFileThatTakesNoMarksIsRefused() async throws {
        let model = MeasureModel(fonts: FakeFonts())
        let locked = try ToolRig(try Pdfs.restricted(.print), password: "")
        locked.attach(model)
        try measure(model, ViewPoint(100, 100), ViewPoint(172, 100))

        await model.action?.run()

        XCTAssertEqual(locked.host.problems.map(\.title), ["Not allowed"])
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertFalse(locked.tab.isDirty)
    }

    func test_aSignedFileAsksBeforeTheMeasurementsAreWritten() async throws {
        let (model, rig) = try attached(try Pdfs.signed(certified: false))
        try measure(model, ViewPoint(100, 100), ViewPoint(172, 100))

        await model.action?.run()
        XCTAssertEqual(rig.host.notices.map(\.title), ["Check before going on"])
        XCTAssertEqual(model.rows.count, 1)

        rig.host.notices[0].action?.run()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(rig.tab.session.undoLabel, "Measure")
    }

    func test_theListIsKeptPerTab() throws {
        let (model, rig) = try attached()
        try measure(model, ViewPoint(0, 0), ViewPoint(72, 0))
        model.detach()

        let other = try ToolRig()
        other.attach(model)
        XCTAssertTrue(model.rows.isEmpty)
        model.detach()

        rig.attach(model)
        XCTAssertEqual(model.rows.count, 1)
    }

    func test_aTurnedPageDropsItsMeasurementsAndSaysSo() async throws {
        let (model, rig) = try attached()
        try measure(model, ViewPoint(0, 0), ViewPoint(72, 0))

        PageOperations.rotate(rig.tab.document, [0], 90)
        try rig.tab.commit("Rotate")
        await waitUntil { model.rows.isEmpty }

        XCTAssertEqual(rig.host.notices.map(\.title), ["Measurements dropped"])
    }

    func test_theViewersOwnHandButtonDisarmsTheKinds() async throws {
        let (model, rig) = try attached()
        try measure(model, ViewPoint(0, 0), ViewPoint(72, 0))
        let tool = try XCTUnwrap(model.tool)
        tool.press(PagePointer(page: 0, point: ViewPoint(5, 5), view: ViewPoint(5, 5), pressed: true, clicks: 1))
        XCTAssertTrue(model.canStartOver)

        rig.viewer.pointerTool = nil

        await waitUntil { model.kind == nil }
        XCTAssertEqual(model.hint, "Pick Distance, Perimeter or Area to measure again.")
        XCTAssertFalse(model.canStartOver)
        XCTAssertEqual(model.rows.count, 1)

        model.pick(.perimeter)
        XCTAssertTrue(rig.viewer.pointerTool === tool)
        XCTAssertEqual(model.kind, .perimeter)
    }

    func test_theReadoutFollowsTheShapeUnderWay() throws {
        let (model, _) = try attached()
        model.pick(.perimeter)
        XCTAssertEqual(model.readout, "—")
        let tool = try XCTUnwrap(model.tool)

        tool.press(PagePointer(page: 0, point: ViewPoint(0, 0), view: ViewPoint(0, 0), pressed: true, clicks: 1))
        tool.press(PagePointer(page: 0, point: ViewPoint(72, 0), view: ViewPoint(72, 0), pressed: true, clicks: 1))

        XCTAssertEqual(model.readout, "25.4 mm")
        XCTAssertTrue(model.canStartOver)
        XCTAssertFalse(model.canFinish)
    }

    func test_takeBackCornerDropsTheLastCornerOfTheShapeUnderWay() throws {
        let (model, _) = try attached()
        model.pick(.area)
        let tool = try XCTUnwrap(model.tool)
        for corner in [ViewPoint(0, 0), ViewPoint(72, 0), ViewPoint(72, 72)] {
            tool.press(PagePointer(page: 0, point: corner, view: corner, pressed: true, clicks: 1))
        }
        XCTAssertTrue(model.canFinish)

        model.takeBack()

        XCTAssertEqual(tool.points.count, 2)
        XCTAssertFalse(model.canFinish)
        XCTAssertTrue(model.canStartOver)
        model.startOver()
        XCTAssertFalse(model.canStartOver)
    }

    func test_aPhoneAsksForTapsAndTheStraightSwitch() throws {
        let rig = try ToolRig(nil)
        let model = MeasureModel(fonts: FakeFonts(), touch: true)
        rig.attach(model)

        XCTAssertEqual(model.hint, "Tap the two ends. Turn on Straight lines to keep them straight.")
        model.pick(.area)
        XCTAssertEqual(model.hint, "Tap each corner, then tap Finish. Turn on Straight lines to keep them straight.")
    }
}
