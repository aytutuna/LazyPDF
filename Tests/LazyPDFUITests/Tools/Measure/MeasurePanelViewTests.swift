#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import XCTest
import LazyPDFKit
@testable import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Measure panel: the view is drawn at the width of the inspector after its model is attached, empty and
// with a measurement waiting. The model has the real tests, in Tests/LazyPDFAppTests/Tools/Measure.

@MainActor
final class MeasurePanelViewTests: XCTestCase {
    func test_thePanelIsDrawnWithItsScaleAndOptions() throws {
        let rig = try ToolViewRig()
        let model = MeasureModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(MeasurePanelView(model: model), height: 700)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 300)
    }

    func test_aBadScaleAddsItsWarning() throws {
        let rig = try ToolViewRig()
        let model = MeasureModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)
        let before = try ToolPicture.ink(try ToolPicture.draw(MeasurePanelView(model: model), height: 700))

        model.setPageValue("0")
        let after = try ToolPicture.ink(try ToolPicture.draw(MeasurePanelView(model: model), height: 700))

        XCTAssertTrue(model.scaleProblem)
        XCTAssertNotEqual(after, before)
    }

    func test_aDrawnCalibrationLineAddsTheRowForItsLength() throws {
        let rig = try ToolViewRig()
        let model = MeasureModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)
        model.startCalibrate()
        let before = try ToolPicture.ink(try ToolPicture.draw(MeasurePanelView(model: model), height: 1600))

        let tool = try XCTUnwrap(model.tool)
        for x in [0.0, 72] {
            tool.press(PagePointer(page: 0, point: ViewPoint(x, 0), view: ViewPoint(x, 0), pressed: true, clicks: 1))
        }
        let drawn = try ToolPicture.ink(try ToolPicture.draw(MeasurePanelView(model: model), height: 1600))
        model.setCalibrateValue("0")
        model.applyCalibration()
        let problem = try ToolPicture.ink(try ToolPicture.draw(MeasurePanelView(model: model), height: 1600))

        XCTAssertEqual(model.calibrateDrawn, "Line drawn: 25.4 mm")
        XCTAssertGreaterThan(drawn, before)
        XCTAssertTrue(model.calibrateProblem)
        XCTAssertGreaterThan(problem, drawn)
    }

#if canImport(AppKit)
    // The row is hosted in a window so the length field has a field editor, and the keys go through the window as typed.
    private func hostedRow() throws -> (MeasureModel, ToolViewRig, NSWindow) {
        let rig = try ToolViewRig()
        let model = MeasureModel(fonts: StandInFonts())
        model.attach(rig.tab, rig.viewer, rig.host)
        model.startCalibrate()
        let tool = try XCTUnwrap(model.tool)
        for x in [0.0, 72] {
            tool.press(PagePointer(page: 0, point: ViewPoint(x, 0), view: ViewPoint(x, 0), pressed: true, clicks: 1))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MeasurePanelView(model: model))
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let field = try XCTUnwrap(fields(in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return (model, rig, window)
    }

    private func fields(in view: NSView) -> [NSTextField] {
        var found = view.subviews.flatMap { fields(in: $0) }
        if let field = view as? NSTextField { found.insert(field, at: 0) }
        return found
    }

    private func press(_ key: String, code: UInt16, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: key,
                                                   charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        window.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func test_returnInTheLengthFieldSetsTheScale() throws {
        let (model, rig, window) = try hostedRow()
        model.setCalibrateValue("2")

        try press("\r", code: 36, in: window)

        XCTAssertNil(model.calibrateDrawn)
        XCTAssertNotEqual(model.scales.scale(rig.tab.document, 0), .actual)
    }

    func test_escapeInTheLengthFieldCancelsTheCalibration() throws {
        let (model, _, window) = try hostedRow()
        XCTAssertNotNil(model.calibrateDrawn)

        try press("\u{1B}", code: 53, in: window)

        XCTAssertNil(model.calibrateDrawn)
    }
#endif

    func test_theRegistryMakesThePanelForTheToolId() throws {
        let rig = try ToolViewRig()
        let context = ToolContext(info: ToolCatalog.find("measure")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "measure", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(panel.view, height: 700)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 300)
        XCTAssertEqual(panel.model.action?.text, "Add to page")
    }
}
#endif
