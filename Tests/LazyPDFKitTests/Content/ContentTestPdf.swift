import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/ContentTestPdf.cs.

enum ContentTestPdf {
    static let helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"

    /// A one-page file: the content is object 4, objects 5 on come from `objects`.
    static func page(_ content: String, _ resources: String = "", _ objects: [String] = []) throws -> PdfDocument {
        try page(latin(content), resources, objects)
    }

    static func page(_ content: [UInt8], _ resources: String = "", _ objects: [String] = []) throws -> PdfDocument {
        try page(content, resources) { pdf in
            for (i, object) in objects.enumerated() { pdf.obj(5 + i, object) }
        }
    }

    /// As above, `more` adds the objects from number 5 on.
    static func page(_ content: String, _ resources: String, _ more: (TestPdf) -> Void) throws -> PdfDocument {
        try page(latin(content), resources, more)
    }

    static func page(_ content: [UInt8], _ resources: String, _ more: (TestPdf) -> Void) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<\(resources)>>>>")
        pdf.stream(4, "", content)
        more(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    static func latin(_ text: String) -> [UInt8] { Latin1.bytes(text) }

    static func parse(_ text: String) -> [ContentOperation] { ContentParser.parse(latin(text)) }

    static func run(_ document: PdfDocument) -> Recorder {
        let recorder = Recorder()
        ContentInterpreter(document).run(document.pages[0], recorder)
        return recorder
    }
}

final class Recorder: ContentVisitor {
    var glyphs: [GlyphInfo] = []
    var renderModes: [Int] = []
    var paths: [(path: PathInfo, state: GraphicsState)] = []
    var images: [ImageInfo] = []
    var shadings: [ShadingInfo] = []
    var events: [String] = []
    var `where`: [(index: Int, formDepth: Int, mcid: Int?)] = []

    var text: String { glyphs.map { $0.unicode ?? "" }.joined() }

    override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
        glyphs.append(glyph)
        renderModes.append(context.state.renderMode)
        `where`.append((context.operatorIndex, context.forms.count, context.mcid))
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        paths.append((path, context.state.clone()))
        `where`.append((context.operatorIndex, context.forms.count, context.mcid))
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        images.append(image)
    }

    override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
        shadings.append(shading)
    }

    override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
        events.append("begin \(marked.tag)" + (marked.mcid.map { " \($0)" } ?? ""))
    }

    override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
        events.append("end \(marked.tag)")
    }

    override func beginForm(_ context: ContentContext, _ form: FormInfo) {
        events.append(form.isPattern ? "pattern" : "form")
    }

    override func endForm(_ context: ContentContext, _ form: FormInfo) {
        events.append("endform")
    }
}
