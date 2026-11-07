#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// Smoke tests of the side panel views: each is drawn at a fixed size with a file that has bookmarks, attachments, layers and
// comments, after its model is attached to it. The models have the real tests, in Tests/LazyPDFAppTests/Panels.

@MainActor
final class PanelViewsTests: XCTestCase {
    private struct Rig {
        let tab: DocumentTab
        let viewer: PanelViewer
        let host: RecordingHost
    }

    private func fixture(_ bytes: [UInt8]? = nil) throws -> Rig {
        let tab = try PanelPdfs.tab(bytes ?? PanelPdfs.full())
        return Rig(tab: tab, viewer: PanelViewer(tab), host: RecordingHost())
    }

    private func draw<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: 280, height: 420).background(Color.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 280)
        XCTAssertEqual(image.height, 420)
        return image
    }

    private func hasInk(_ image: CGImage) throws -> Bool {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] != 255 || pixels[$0 + 1] != 255 || pixels[$0 + 2] != 255 }
    }

    func test_thePagesPanelDrawsALabelForEveryPage() throws {
        let rig = try fixture()
        let model = PagesModel()
        model.attach(rig.tab, rig.viewer, rig.host)

        _ = try draw(PagesPanelView(model: model))
        // A scroll view draws nothing in a renderer with no window, so the page's own view is drawn too.
        let image = try draw(PageThumbView(thumb: model.thumbs[0], isCurrent: true, choose: {}))

        XCTAssertEqual(model.thumbs.count, 2)
        XCTAssertTrue(try hasInk(image))
    }

    func test_theBookmarksPanelHasTheOutlineOrASentenceWhenThereIsNone() throws {
        let rig = try fixture()
        let model = BookmarksModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        _ = try draw(BookmarksPanelView(model: model))
        XCTAssertEqual(model.nodes.count, 2)

        let bare = try fixture(TestFile.plain())
        let empty = BookmarksModel()
        empty.attach(bare.tab, bare.viewer, bare.host)
        let image = try draw(BookmarksPanelView(model: empty))

        XCTAssertTrue(empty.nodes.isEmpty)
        XCTAssertTrue(try hasInk(image))
    }

    func test_theAttachmentsPanelListsTheFiles() throws {
        let rig = try fixture()
        let model = AttachmentsModel(openedFolder: FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-ui-tests"))
        model.attach(rig.tab, rig.viewer, rig.host)

        _ = try draw(AttachmentsPanelView(model: model))

        XCTAssertEqual(model.rows.map { $0.name }, ["note.txt", "run.exe"])
    }

    func test_theLayersPanelListsTheLayers() throws {
        let rig = try fixture()
        let model = LayersModel()
        model.attach(rig.tab, rig.viewer, rig.host)

        _ = try draw(LayersPanelView(model: model))

        XCTAssertEqual(model.roots.map { $0.name }, ["Black box", "Notes"])
    }

    func test_theCommentsPanelListsTheComments() throws {
        let rig = try fixture()
        try PanelPdfs.comment(rig.tab, page: 0, author: "Ada", text: "Look")
        let model = CommentsModel()
        model.attach(rig.tab, rig.viewer, rig.host)
        model.select(model.rows[0].id)

        _ = try draw(CommentsPanelView(model: model))

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertNotNil(model.selectedRow)
    }

    func test_theSignaturesPanelDrawsWhileTheCheckRuns() throws {
        let rig = try fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-ui-" + UUID().uuidString)
        let model = SignaturesModel(trust: SignatureTrust(directory: folder))
        model.attach(rig.tab, rig.viewer, rig.host)

        _ = try draw(SignaturesPanelView(model: model))

        XCTAssertEqual(model.note, "Checking the signatures")
    }

    func test_theSearchPanelHasTheSummary() throws {
        let rig = try fixture()
        let model = SearchModel()
        model.attach(rig.tab, rig.viewer, rig.host)

        _ = try draw(SearchPanelView(model: model))

        XCTAssertEqual(model.summary, "Search the file to list every match here.")
    }

    func test_theSidePanelViewShowsEachPanelOfTheRail() throws {
        let rig = try fixture()

        for info in SidePanelCatalog.all {
            _ = try draw(SidePanelView(id: info.id, tab: rig.tab, viewer: rig.viewer, host: rig.host,
                                       folders: DefaultAppFolders()))
        }
        _ = try draw(SidePanelView(id: "nothing", tab: rig.tab, viewer: rig.viewer, host: rig.host))
    }

    func test_aPagePictureKeepsItsSizeAndColours() throws {
        let image = try XCTUnwrap(PanelImage.make(PdfRgbaImage(2, 1, [255, 0, 0, 255, 0, 0, 255, 255])))

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        var pixels = [UInt8](repeating: 0, count: 8)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(pixels, [255, 0, 0, 255, 0, 0, 255, 255])
        XCTAssertNil(PanelImage.make(PdfRgbaImage(0, 0, [])))
    }
}

private enum TestFile {
    /// One page with nothing in it: no bookmarks, attachments, layers or comments.
    static func plain() throws -> [UInt8] {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"]
        var file = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(file.utf8)
    }
}
#endif
