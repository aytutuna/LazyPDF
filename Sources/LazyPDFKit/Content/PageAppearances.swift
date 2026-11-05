import Foundation

// Twin of windows/LazyPDF.Core/Content/PageAppearances.cs: the normal appearances of a page's annotations, each with
// the matrix that carries it onto the annotation's /Rect.

enum PageAppearances {
    /// With `shownOnly`, annotations that are hidden, not for viewing, or popups are left out.
    static func of(_ document: PdfDocument, _ page: PdfPage, shownOnly: Bool = false) -> [(form: PdfStream, matrix: PdfMatrix)] {
        var result: [(form: PdfStream, matrix: PdfMatrix)] = []
        for item in document.array(page.dictionary, "Annots")?.items ?? [] {
            guard let annotation = document.resolve(item) as? PdfDictionary, let rect = document.rect(annotation, "Rect") else { continue }
            if shownOnly && (((document.integer(annotation, "F") ?? 0) & 0b100010) != 0 || document.name(annotation, "Subtype") == "Popup") { continue }
            let normal = document.resolve(document.dict(annotation, "AP")?["N"])
            var found = normal as? PdfStream
            if let states = normal as? PdfDictionary, let state = document.name(annotation, "AS") {
                found = document.resolve(states[state]) as? PdfStream
            }
            guard let form = found, let box = document.rect(form.dictionary, "BBox") else { continue }
            let own = PdfMatrix.fromArray(document.array(form.dictionary, "Matrix")) { document.resolve($0) } ?? PdfMatrix.identity
            let moved = own.transform(box)
            if moved.width < 1e-6 || moved.height < 1e-6 { continue }
            let sx = rect.width / moved.width, sy = rect.height / moved.height
            result.append((form, PdfMatrix(sx, 0, 0, sy, rect.left - moved.left * sx, rect.bottom - moved.bottom * sy)))
        }
        return result
    }
}
