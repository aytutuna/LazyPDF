#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// Smoke tests of the Pages and Combine panels: each view is drawn at the width of the inspector after its model is attached, and
// the organize view at the size of a stage. The models have the real tests, in Tests/LazyPDFAppTests/Tools/Pages and Combine.

@MainActor
final class PagesViewTests: XCTestCase {
    private func askedOf(_ question: SourceQuestion, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where question.asking == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(question.asking, file: file, line: line)
    }

    func test_thePagesPanelIsDrawnWithItsBarAndSections() throws {
        let rig = try ToolViewRig(StandInPdfs.text(4))
        let model = PagesToolModel()
        model.attach(rig.tab, rig.viewer, rig.host)

        let image = try ToolPicture.draw(PagesToolPanelView(model: model), height: 900)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 500)
        XCTAssertEqual(model.grid.cells.count, 4)
    }

    func test_theRegistryMakesThePanelAndTheStageOfThePagesTool() throws {
        let rig = try ToolViewRig(StandInPdfs.text(3))
        let context = ToolContext(info: ToolCatalog.find("pages")!, folders: StandInFolders(root: FileManager.default.temporaryDirectory))
        let panel = try XCTUnwrap(ToolRegistry.panel(for: "pages", context))
        panel.model.attach(rig.tab, rig.viewer, rig.host)

        XCTAssertNotNil(panel.stage)
        XCTAssertNil(panel.model.action)
        let image = try ToolPicture.draw(panel.view, height: 900)
        XCTAssertGreaterThan(try ToolPicture.ink(image), 500)
    }

    func test_theOrganizeViewIsDrawnOnTheStage() throws {
        let rig = try ToolViewRig(StandInPdfs.text(6))
        let model = PagesToolModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        model.openOrganize()
        let organize = try XCTUnwrap(model.organize)

        let image = try ToolPicture.draw(OrganizeView(model: organize), width: 900, height: 500)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 300)
        XCTAssertNotNil(PagesStageView(model: model))
    }

    func test_theQuestionOfAProtectedFileIsDrawn() async throws {
        let question = SourceQuestion()
        let job = Task { await question.password(for: "b.pdf", wrong: true) }
        await askedOf(question)
        let ask = try XCTUnwrap(question.asking)

        let image = try ToolPicture.draw(SourceAskSheet(question: question, ask: ask), width: 420, height: 260)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 200)
        question.answer(password: nil)
        let answer = await job.value
        XCTAssertNil(answer)
    }

    func test_theQuestionOfAFileForRecipientsIsDrawn() async throws {
        let question = SourceQuestion()
        question.choices = { [StandInKeys.alice] }
        let job = Task { await question.certificate(for: "b.pdf", wrong: false) }
        await askedOf(question)
        let ask = try XCTUnwrap(question.asking)

        let image = try ToolPicture.draw(SourceAskSheet(question: question, ask: ask), width: 420, height: 320)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 200)
        XCTAssertEqual(ask.choices.map(\.name), ["Alice"])
        question.giveUp()
        let answer = await job.value
        XCTAssertNil(answer)
    }
}
#endif
