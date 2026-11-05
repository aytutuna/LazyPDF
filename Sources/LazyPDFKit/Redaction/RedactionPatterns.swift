import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionPatterns.cs: which patterns can paint under a mark without holding
// anything that was on the page (ISO 32000-1 8.7): an axial or radial shading. A tiling cell is a drawing of its own, a
// signature or a picture made of small shapes, and taking the path under the mark out of the page leaves the cell in the
// file; a mesh and a pattern with a graphics state of its own can hold the marked thing too. A page that paints one under a
// mark is not redacted in place.

enum RedactionPatterns {
    static func plain(_ document: PdfDocument, _ pattern: PdfObject) -> Bool {
        guard let shaded = pattern as? PdfDictionary, document.integer(shaded, "PatternType") == 2, !shaded.containsKey("ExtGState") else { return false }
        let type = document.integer(document.resolve(shaded["Shading"]) as? PdfDictionary, "ShadingType")
        return type == 2 || type == 3
    }
}
