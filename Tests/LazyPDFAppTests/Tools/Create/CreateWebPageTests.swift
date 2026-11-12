import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The web page source of Create without a web view: the layout, the rules, the model and the job around a renderer that
// answers at once. The drawing itself is WebKit's and is checked on the Apple CI.

@MainActor
private final class FakeWebRenderer: WebPageRenderer {
    var failure: WebPageError?
    private(set) var asked: [(URL, WebPageLayout)] = []

    func render(_ page: URL, _ layout: WebPageLayout) async throws -> (bytes: [UInt8], pages: Int) {
        asked.append((page, layout))
        if let failure { throw failure }
        let made = try PdfFromText.create("Hello", fonts: FakeFonts(), setup: PdfPageSetup())
        return (made.bytes, made.pages)
    }
}

@MainActor
private final class PagePicker: ToolFilePicker {
    var files: [ToolFile] = []
    private(set) var asked: [[ToolFileKind]] = []

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        asked.append(kinds)
        return files
    }

    func pickFolder() async -> ToolFile? { nil }
}

@MainActor
final class CreateWebPageTests: XCTestCase {
    private func page(_ f: ViewModelFixture, _ name: String = "story.html", _ html: String = "<p>Hi</p>") -> URL {
        f.dir.file(name, [UInt8](html.utf8))
    }

    private func make(_ f: ViewModelFixture, _ file: URL, _ renderer: WebPageRenderer?) async throws {
        try await CreateJob.run(f.vm, FakeCodec(), FakeFonts(), CreateRequest(.web, PdfPageSetup(), "a.pdf", files: [file]), web: renderer)
    }

    func test_layoutFollowsPaperOrientationAndMargin() {
        let a4 = WebPageLayout(PdfPageSetup(paper: .a4, orientation: .auto, margin: 36))
        XCTAssertEqual(a4.width, 595.276, accuracy: 0.001)
        XCTAssertEqual(a4.height, 841.89, accuracy: 0.001)
        XCTAssertEqual(a4.contentWidth, 595.276 - 72, accuracy: 0.001)

        let letter = WebPageLayout(PdfPageSetup(paper: .letter, orientation: .landscape, margin: 0))
        XCTAssertEqual(letter.width, 792)
        XCTAssertEqual(letter.height, 612)
        XCTAssertEqual(letter.contentHeight, 612)

        let picture = WebPageLayout(PdfPageSetup(paper: .picture, orientation: .portrait))
        XCTAssertEqual(picture.width, 595.276, accuracy: 0.001)
    }

    func test_theRuleListIsJsonThatBlocksTheNetwork() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(WebPageRules.blockNetwork.utf8)) as? [[String: [String: String]]]
        XCTAssertEqual(rules?.count, 1)
        XCTAssertEqual(rules?[0]["action"]?["type"], "block")
        let filter = try XCTUnwrap(rules?[0]["trigger"]?["url-filter"])
        let expression = try NSRegularExpression(pattern: filter)
        for url in ["http://a.example/x.png", "https://a.example/", "wss://a.example/", "ftp://a.example/"] {
            XCTAssertNotNil(expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), url)
        }
        let local = "file:///Users/me/a.png"
        XCTAssertNil(expression.firstMatch(in: local, range: NSRange(local.startIndex..., in: local)))
    }

    func test_remotePartsAreSpottedButLinksAreNot() {
        let remote = [
            #"<img src="https://a.example/p.png">"#,
            "<IMG SRC='//a.example/p.png'>",
            #"<link rel="stylesheet" href="http://a.example/s.css">"#,
            #"<style>body { background: url(https://a.example/b.png) }</style>"#,
            #"<style>@import "https://a.example/s.css";</style>"#,
            #"<script src=https://a.example/s.js></script>"#,
        ]
        for html in remote { XCTAssertTrue(WebPageRules.namesRemoteParts(html), html) }
        let local = [
            #"<a href="https://a.example/">link</a>"#,
            #"<img src="pic.png">"#,
            #"<p>see https://a.example/p.png</p>"#,
            "",
        ]
        for html in local { XCTAssertFalse(WebPageRules.namesRemoteParts(html), html) }
    }

    func test_aTagThatNeverClosesIsReadInShortOrder() {
        let html = String(repeating: "<img ", count: 20_000) + String(repeating: "x", count: 100_000)
        let start = Date()
        XCTAssertFalse(WebPageRules.namesRemoteParts(html))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func test_aTagStartRepeatedToTheSizeLimitIsReadInShortOrder() {
        let html = String(repeating: "<img ", count: WebPageRules.mostBytes / 5)
        let start = Date()
        XCTAssertFalse(WebPageRules.namesRemoteParts(html))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func test_remotePartsAreSpottedAfterOtherAttributesAndOnlyInsideTheTag() {
        XCTAssertTrue(WebPageRules.namesRemoteParts(#"<img alt="a" class=b SRC = " HTTPS://a.example/p.png">"#))
        XCTAssertTrue(WebPageRules.namesRemoteParts(#"<img <img src=//a.example/p.png>"#))
        XCTAssertFalse(WebPageRules.namesRemoteParts(#"<img alt="x"><p data-src="//a.example/">"#))
        XCTAssertFalse(WebPageRules.namesRemoteParts(#"<img xsrc="//a.example/p.png">"#))
    }

    func test_htmlAndHtmAreWebPages() {
        XCTAssertTrue(FileKinds.isWebPage(URL(fileURLWithPath: "/a/b.HTML")))
        XCTAssertTrue(FileKinds.isWebPage(URL(fileURLWithPath: "/a/b.htm")))
        XCTAssertFalse(FileKinds.isWebPage(URL(fileURLWithPath: "/a/b.txt")))
    }

    func test_theSourceIsOnlyOfferedWithARenderer() {
        XCTAssertFalse(CreateModel(host: nil, codec: FakeCodec(), fonts: FakeFonts()).offersWebPage)
        XCTAssertTrue(CreateModel(host: nil, codec: FakeCodec(), fonts: FakeFonts(), web: FakeWebRenderer()).offersWebPage)
    }

    func test_pickingAPageEnablesCreateAndNamesTheRequest() async throws {
        let f = ViewModelFixture(self)
        let picker = PagePicker()
        f.vm.filePicker = picker
        let model = CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts(), web: FakeWebRenderer())
        model.choose(.webPage)
        XCTAssertFalse(model.canRun)
        XCTAssertNil(model.request())

        picker.files = [ToolFile(url: page(f))]
        await model.pickWebPage()

        XCTAssertEqual(picker.asked, [[.webPage]])
        XCTAssertTrue(model.canRun)
        XCTAssertTrue(model.showsMargin)
        let request = try XCTUnwrap(model.request())
        XCTAssertEqual(request.title, "story.pdf")
        XCTAssertEqual(request.files.map(\.lastPathComponent), ["story.html"])
        XCTAssertTrue(request.source == .web)
    }

    func test_givingUpThePickerKeepsThePageChosenBefore() async throws {
        let f = ViewModelFixture(self)
        let picker = PagePicker()
        f.vm.filePicker = picker
        let model = CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts(), web: FakeWebRenderer())
        picker.files = [ToolFile(url: page(f))]
        await model.pickWebPage()
        picker.files = []

        await model.pickWebPage()

        XCTAssertEqual(model.webPage?.url.lastPathComponent, "story.html")
    }

    func test_aRunHandsThePageAndTheSetupToTheRenderer() async throws {
        let f = ViewModelFixture(self)
        let renderer = FakeWebRenderer()
        let picker = PagePicker()
        f.vm.filePicker = picker
        picker.files = [ToolFile(url: page(f))]
        let model = CreateModel(host: f.vm, codec: FakeCodec(), fonts: FakeFonts(), web: renderer)
        model.choose(.webPage)
        await model.pickWebPage()
        model.paper = .letter
        model.margin = 72

        await model.run()

        XCTAssertEqual(renderer.asked.count, 1)
        XCTAssertEqual(renderer.asked[0].0.lastPathComponent, "story.html")
        XCTAssertEqual(renderer.asked[0].1, WebPageLayout(PdfPageSetup(paper: .letter, orientation: .auto, margin: 72)))
        XCTAssertEqual(f.vm.activeDocument?.title, "story.pdf")
        XCTAssertNil(f.vm.message)
    }

    func test_aPageNamingTheInternetOpensWithANotice() async throws {
        let f = ViewModelFixture(self)

        try await make(f, page(f, "shop.html", #"<img src="https://a.example/p.png">"#), FakeWebRenderer())

        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.title, "Some left out")
    }

    func test_aFileOverTheLimitIsRefusedBeforeTheViewSeesIt() async throws {
        let f = ViewModelFixture(self)
        let renderer = FakeWebRenderer()
        let big = f.dir.file("big.html", [UInt8](repeating: 0x20, count: WebPageRules.mostBytes + 1))

        try await make(f, big, renderer)

        XCTAssertEqual(f.vm.message?.title, "Page is too big")
        XCTAssertTrue(renderer.asked.isEmpty)
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_eachRendererFailureHasItsOwnProblem() async throws {
        let titles: [WebPageError: String] = [.timedOut: "Page took too long", .tooLong: "Page is too long", .couldNotLoad: "Page cannot be read"]
        for (failure, title) in titles {
            let f = ViewModelFixture(self)
            let renderer = FakeWebRenderer()
            renderer.failure = failure

            try await make(f, page(f), renderer)

            XCTAssertEqual(f.vm.message?.title, title)
            XCTAssertTrue(f.vm.documents.isEmpty)
        }
    }

    func test_aMissingFileIsAProblemNotACrash() async throws {
        let f = ViewModelFixture(self)

        try await make(f, URL(fileURLWithPath: "/no/such/page.html"), FakeWebRenderer())

        XCTAssertEqual(f.vm.message?.title, "Page cannot be read")
    }

    func test_withoutARendererThePageCannotBeMade() async throws {
        let f = ViewModelFixture(self)

        try await make(f, page(f), nil)

        XCTAssertEqual(f.vm.message?.title, "Page cannot be read")
    }
}
