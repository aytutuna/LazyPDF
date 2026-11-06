import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/TagScan.cs: what the tagger needs from a run of the interpreter that the text
// layout does not give: the images, and for a form its `Do` in the page's own content, since a marked-content sequence can
// only be opened around that.

/// An image drawn by a page, with the page-level operation that draws it (the `Do` of the outermost form it sits in).
struct ScannedImage {
    let operation: Int
    let bounds: PdfRect
}

final class TagScan: ContentVisitor {
    private var top = -1

    private(set) var truncated = false

    private(set) var images: [ScannedImage] = []

    private(set) var formOperations: [ObjectIdentifier: Int] = [:]

    /// Forms drawn from more than one place; their content cannot be told apart per drawing.
    private(set) var repeated = Set<ObjectIdentifier>()

    static func run(_ interpreter: ContentInterpreter, _ page: PdfPage) -> TagScan {
        let scan = TagScan()
        let patterns = interpreter.walkPatterns
        interpreter.walkPatterns = false
        defer { interpreter.walkPatterns = patterns }
        interpreter.run(page, scan)
        scan.truncated = interpreter.isTruncated
        return scan
    }

    override func beginForm(_ context: ContentContext, _ form: FormInfo) {
        if context.forms.count == 1 { top = context.operatorIndex }
        let key = ObjectIdentifier(form.stream)
        if let known = formOperations[key] {
            if known != top { repeated.insert(key) }
        } else {
            formOperations[key] = top
        }
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        images.append(ScannedImage(operation: context.forms.isEmpty ? context.operatorIndex : top, bounds: image.bounds))
    }
}
