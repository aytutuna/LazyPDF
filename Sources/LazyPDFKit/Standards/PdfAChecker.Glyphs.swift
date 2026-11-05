import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Glyphs.cs: text in content the interpreter does not run: the soft mask
// groups of graphics states, the glyph procedures of Type 3 fonts and the cells of tiling patterns that text or an image mask
// is painted with. Nothing is decoded there, so a font that shows text is held to the font rules with no codes noted for it.
// A group or glyph is scanned as painted only once something paints with it; before that its fonts count but its device
// colour spaces do not.

extension PdfAChecker {
    static let maxSavedStates = 256

    private func scanProcedures(_ font: PdfDictionary, _ scope: PdfDictionary?, _ place: String, _ painted: Bool, _ depth: Int) {
        if let done = proceduresScanned[ObjectIdentifier(font)], done || !painted { return }
        proceduresScanned[ObjectIdentifier(font)] = painted
        let resources = document.dict(font, "Resources") ?? scope
        for case let procedure as PdfStream in entries(font, "CharProcs") { scanText(procedure, resources, place, painted, depth + 1) }
    }

    func scanProcedure(_ font: PdfFont, _ code: Int, _ scope: PdfDictionary?, _ place: String) {
        if let name = font.glyphNameOf(code), let procedure = document.stream(document.dict(font.dictionary, "CharProcs"), name) {
            scanText(procedure, document.dict(font.dictionary, "Resources") ?? scope, place, true, 1)
        }
    }

    // Tiling patterns are run by the interpreter only when a path is painted with them; text and image masks painted with one never enter the cell.
    func scanCell(_ color: PdfColor, _ place: String, _ scope: PdfDictionary?) {
        if let cell = color.pattern as? PdfStream, document.integer(cell.dictionary, "PatternType") == 1 {
            scanText(cell, document.dict(cell.dictionary, "Resources") ?? scope, place, true)
        }
    }

    // The group of a soft mask is drawn when something is painted under it, which the interpreter does not follow.
    func useMask(_ context: ContentContext, _ place: String, _ scope: PdfDictionary?) {
        if let mask = context.state.softMask, masksApplied.insert(ObjectIdentifier(mask)).inserted, let group = document.stream(mask, "G") {
            scanText(group, document.dict(group.dictionary, "Resources") ?? scope, place, true)
        }
    }

    func scanText(_ stream: PdfStream, _ resources: PdfDictionary?, _ place: String, _ painted: Bool, _ depth: Int = 0) {
        if overBudget { return }
        if depth >= Self.maxScanDepth {
            add("6.1.7", place, PdfAText.tooMuchContent)
            return
        }
        let key = ObjectIdentifier(stream)
        if painted ? !textPainted.insert(key).inserted : textScanned.contains(key) { return }
        textScanned.insert(key)
        let operations: [ContentOperation]
        do {
            let data = try document.data(stream, Self.maxStreamBytes)
            work += data.count
            operations = try ContentParser.parse(data, Self.maxOperations)
        } catch {
            unreadable(place)
            return
        }
        var font: PdfDictionary?
        var mode = 0, overflow = 0
        var saved: [(font: PdfDictionary?, mode: Int)] = []
        for op in operations {
            let name = op.operands.last as? PdfName
            switch op.operator {
            case "q":
                if saved.count < Self.maxSavedStates { saved.append((font, mode)) } else { overflow += 1 }
            case "Q":
                if overflow > 0 {
                    overflow -= 1
                } else if let top = saved.popLast() {
                    (font, mode) = top
                }
            case "Tf":
                if op.operands.count > 1, let fontName = op.operands[op.operands.count - 2] as? PdfName {
                    font = document.dict(document.dict(resources, "Font"), fontName.value)
                }
            case "Tr":
                if let render = op.operands.last as? PdfNumber { mode = Int(saturating32: render.value) }
            case "Tj", "TJ", "'", "\"":
                guard let font else { break }
                if mode != 3 { renderedFonts.insert(ObjectIdentifier(font)) }
                _ = usesOf(font)
                if document.name(font, "Subtype") == "Type3" { scanProcedures(font, resources, place, painted, depth) }
            case "Do":
                if let name, let xobject = document.stream(document.dict(resources, "XObject"), name.value) {
                    let subtype = document.name(xobject.dictionary, "Subtype")
                    if subtype == "Form" {
                        scanText(xobject, document.dict(xobject.dictionary, "Resources") ?? resources, place, painted, depth + 1)
                    } else if subtype == "Image" && document.bool(xobject.dictionary, "ImageMask") != true {
                        checkColorSpace(xobject.dictionary["ColorSpace"], place, resources, painted)
                    }
                }
            case "sh":
                if let name { checkShading(document.dict(resources, "Shading")?[name.value], place, resources, painted) }
            case "cs", "CS":
                if let name { checkColorSpace(document.dict(resources, "ColorSpace")?[name.value] ?? name, place, resources, painted) }
            case "gs":
                if let name, let mask = document.dict(document.dict(document.dict(resources, "ExtGState"), name.value), "SMask"),
                   let group = document.stream(mask, "G") {
                    scanText(group, document.dict(group.dictionary, "Resources") ?? resources, place, painted, depth + 1)
                }
            default:
                break
            }
        }
    }
}
