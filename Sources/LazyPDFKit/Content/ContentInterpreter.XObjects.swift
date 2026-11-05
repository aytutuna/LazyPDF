import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentInterpreter.XObjects.cs: images, shadings, forms, tiling patterns and
// marked content.

extension ContentInterpreter {
    private static let overflowMarker = MarkedContent("", nil, nil, nil)

    private func operations(_ stream: PdfStream) -> [ContentOperation] {
        let key = ObjectIdentifier(stream)
        if let cached = formOperations[key] { return cached.operations }
        let operations: [ContentOperation]
        var size = 0
        do {
            let data = try document.data(stream, Self.maxFormSize)
            size = data.count
            operations = try ContentParser.parse(data, Self.maxFormOperations)
        } catch {
            return keep(stream, [], size)
        }
        return keep(stream, operations, size)
    }

    private func keep(_ stream: PdfStream, _ operations: [ContentOperation], _ size: Int) -> [ContentOperation] {
        if formOperations.count < Self.maxCachedForms && cachedOperations + operations.count <= Self.maxCachedOperations {
            formOperations[ObjectIdentifier(stream)] = (stream, operations)
            cachedOperations += operations.count
        } else {
            // Not kept, so every Do of it inflates and scans the stream again.
            budget -= size >> 6
        }
        return operations
    }

    func paint(_ op: ContentOperation) {
        guard let name = nameOperand(op), let xobject = findResource("XObject", name) as? PdfStream else { return }
        let subtype = document.name(xobject.dictionary, "Subtype")
        if subtype == "Image" {
            paintImage(name, xobject, nil, xobject.dictionary)
        } else if subtype == "Form" || (subtype == nil && xobject.dictionary.containsKey("BBox")) {
            enterForm(xobject, name, document.dict(xobject.dictionary, "OC"))
        }
    }

    func paintInlineImage(_ op: ContentOperation) {
        guard let image = op.image else { return }
        let dictionary = image.expanded { self.findResource("ColorSpace", $0) }
        paintImage(nil, nil, image, dictionary)
    }

    private func paintImage(_ name: String?, _ stream: PdfStream?, _ inline: InlineImage?, _ dictionary: PdfDictionary) {
        let width = Swift.min(Swift.max(document.integer(dictionary, "Width") ?? 0, 0), Int(Int32.max))
        let height = Swift.min(Swift.max(document.integer(dictionary, "Height") ?? 0, 0), Int(Int32.max))
        let bounds = state.ctm.transform(PdfRect(0, 0, 1, 1))
        visitor.paintImage(context, ImageInfo(name, stream, inline, dictionary, width, height,
                                              document.bool(dictionary, "ImageMask") == true, state.ctm, bounds, document.dict(dictionary, "OC")))
    }

    func paintShading(_ op: ContentOperation) {
        if let name = nameOperand(op), let shading = findResource("Shading", name), shading is PdfDictionary || shading is PdfStream {
            visitor.paintShading(context, ShadingInfo(name, shading, state.clip))
        }
    }

    func enterForm(_ form: PdfStream, _ name: String?, _ optionalContent: PdfDictionary?) {
        let inner = state.clone()
        let matrix = PdfMatrix.fromArray(document.array(form.dictionary, "Matrix")) { self.document.resolve($0) } ?? PdfMatrix.identity
        inner.ctm = matrix.multiply(inner.ctm)
        runContent(form, name, false, inner, optionalContent)
    }

    // A tiling pattern's cell is run once, when something is first painted with it (8.7.3).
    func walkPattern(_ color: PdfColor) {
        guard walkPatterns, let pattern = color.pattern as? PdfStream, document.integer(pattern.dictionary, "PatternType") == 1 else { return }
        if !walkedPatterns.insert(ObjectIdentifier(pattern)).inserted { return }
        let matrix = PdfMatrix.fromArray(document.array(pattern.dictionary, "Matrix")) { self.document.resolve($0) } ?? PdfMatrix.identity
        let inner = GraphicsState()
        inner.ctm = matrix.multiply(base)
        inner.clip = Self.unbounded
        if document.integer(pattern.dictionary, "PaintType") == 2 {
            inner.fillColor = PdfColor(color.space.base ?? ColorSpaceInfo.deviceGray, color.components)
            inner.strokeColor = inner.fillColor
        }
        runContent(pattern, color.patternName?.value, true, inner, nil)
    }

    private func runContent(_ stream: PdfStream, _ name: String?, _ isPattern: Bool, _ inner: GraphicsState, _ optionalContent: PdfDictionary?) {
        let id = ObjectIdentifier(stream)
        if context.forms.count >= Self.maxFormDepth || activeForms.contains(id) { return }
        let operations = self.operations(stream)
        activeForms.insert(id)
        let outer = (state: state, stack: stack, base: base, tm: tm, tlm: tlm, path: path, clip: pendingClip)
        let bbox = document.rect(stream.dictionary, "BBox")
        let area = bbox.map { inner.ctm.transform($0) } ?? inner.clip
        if bbox != nil { inner.clip = inner.clip.intersect(area) }
        state = inner
        context.state = inner
        stack = []
        base = inner.ctm
        path = []
        resetPath()
        resources.append(document.dict(stream.dictionary, "Resources"))
        context.forms.append(stream)
        let info = FormInfo(stream, name, inner.ctm, area, isPattern, optionalContent)
        let index = context.operatorIndex
        let operation = context.operation
        visitor.beginForm(context, info)
        execute(operations)
        context.operatorIndex = index
        context.operation = operation
        visitor.endForm(context, info)
        context.forms.removeLast()
        resources.removeLast()
        (state, stack, base, tm, tlm) = (outer.state, outer.stack, outer.base, outer.tm, outer.tlm)
        context.state = state
        path = outer.path
        pendingClip = outer.clip
        syncText()
        activeForms.remove(id)
    }

    func beginMarkedContent(_ op: ContentOperation) {
        if context.marked.count >= Self.maxMarkedDepth {
            context.marked.append(Self.overflowMarker)
            return
        }
        let tag = nameOperand(op) ?? ""
        var properties: PdfDictionary?
        if op.operator == "BDC" && op.operands.count >= 2 {
            let last = op.operands[op.operands.count - 1]
            if let inline = last as? PdfDictionary {
                properties = inline
            } else if let key = last as? PdfName {
                properties = findResource("Properties", key.value) as? PdfDictionary
            }
        }
        // The C# casts a long to int?, which wraps; a value past the int range is no structure element at all.
        let mcid = properties.flatMap { document.integer($0, "MCID") }.flatMap { Int32(exactly: $0) }.map { Int($0) }
        let marked = MarkedContent(tag, properties, mcid, tag == "OC" ? properties : nil)
        context.marked.append(marked)
        visitor.beginMarked(context, marked)
    }

    func endMarkedContent() {
        if context.marked.count <= markedFloor { return }
        guard let marked = context.marked.last else { return }
        if marked !== Self.overflowMarker { visitor.endMarked(context, marked) }
        context.marked.removeLast()
    }
}
