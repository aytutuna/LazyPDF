import Foundation

// Twin of windows/LazyPDF.Core/Stamps/PdfStamper.Watermark.cs: watermarks and backgrounds.

extension PdfStamper {
    func watermark(_ id: Int, _ spec: WatermarkSpec) throws -> StampRun {
        let text = spec.text ?? ""
        let hasText = !text.isEmpty
        precondition(hasText != (spec.image != nil), StampsText.needsContent)
        let targets = self.targets(spec.pages)
        var font: PdfDrawFont?
        if hasText && !targets.isEmpty { font = try self.font(spec.fontFamily, spec.fontStyle, [text]) }
        let layer = try self.layer(id, spec.layerName)
        let state = try opacity(spec.opacity)
        let lines = Self.lines(text)
        // 64 UTF-16 units; half of a surrogate pair at the cut reads as U+FFFD, which a Swift string cannot avoid.
        let label = hasText ? String(decoding: Array(lines.joined(separator: " ").utf16.prefix(64)), as: UTF16.self) : "image"

        for index in targets {
            let page = document.pages[index]
            let canvas = StampCanvas(page, id, layer != nil)
            var width = spec.scale * canvas.width
            var height: Double
            var size = 0.0
            if let font {
                let widest = lines.map { font.width($0, 100) }.max() ?? 0
                size = widest > 0 ? Swift.min(Swift.max(width / widest * 100, 1), 1000) : 12
                width = widest * size / 100
                height = Double(lines.count - 1) * font.lineHeight(size) + (font.ascent - font.descent) * size
            } else {
                height = spec.image.map { width * Double($0.height) / Double($0.width) } ?? 0
            }
            var (x, y) = Self.anchored(spec.anchor, canvas, width, height)
            x += spec.offsetX
            y -= spec.offsetY

            canvas.beginArtifact("Pagination", "Watermark")
            canvas.writer.save().concat(StampCanvas.place(x, y, width, height, spec.rotation))
            if state != nil { canvas.writer.graphicsState(StampStreams.stateName(id)) }
            if let font {
                canvas.writer.fillRgb(spec.color.r, spec.color.g, spec.color.b).beginText().font(StampStreams.fontName(id), size)
                for (i, line) in lines.enumerated() {
                    let baseline = height - font.ascent * size - Double(i) * font.lineHeight(size)
                    let left = (width - font.width(line, size)) / 2
                    canvas.writer.textMatrix(PdfMatrix.translate(left, baseline)).show(font, line, size)
                }
                canvas.writer.endText()
            } else {
                canvas.writer.paint(StampStreams.imageName(id), PdfMatrix.scale(width, height))
            }
            canvas.writer.restore()
            canvas.endArtifact()
            try finish(page, canvas, id, .watermark, label, spec.behind, font?.reference, spec.image?.reference, state, layer)
        }
        return StampRun(id: id, pages: targets.count, nextBates: 0, missing: font?.missing ?? [])
    }

    func background(_ id: Int, _ spec: BackgroundSpec) throws -> StampRun {
        precondition(spec.color != nil || spec.image != nil, StampsText.needsContent)
        let targets = self.targets(spec.pages)
        let layer = try self.layer(id, spec.layerName)
        let state = try opacity(spec.opacity)

        for index in targets {
            let page = document.pages[index]
            let canvas = StampCanvas(page, id, layer != nil)
            let w = canvas.width, h = canvas.height
            canvas.beginArtifact("Background", nil, page.cropBox)
            canvas.writer.save()
            if state != nil { canvas.writer.graphicsState(StampStreams.stateName(id)) }
            if let c = spec.color { canvas.writer.fillRgb(c.r, c.g, c.b).rect(0, 0, w, h).fill() }
            if let image = spec.image {
                var sx = w / Double(image.width), sy = h / Double(image.height)
                if spec.fit == .cover {
                    sx = Swift.max(sx, sy)
                    sy = sx
                } else if spec.fit == .contain {
                    sx = Swift.min(sx, sy)
                    sy = sx
                }
                let iw = Double(image.width) * sx, ih = Double(image.height) * sy
                canvas.writer.rect(0, 0, w, h).clip()
                canvas.writer.paint(StampStreams.imageName(id), PdfMatrix(iw, 0, 0, ih, (w - iw) / 2, (h - ih) / 2))
            }
            canvas.writer.restore()
            canvas.endArtifact()
            try finish(page, canvas, id, .background, nil, true, nil, spec.image?.reference, state, layer)
        }
        return StampRun(id: id, pages: targets.count, nextBates: 0, missing: [])
    }

    private static func anchored(_ anchor: StampAnchor, _ canvas: StampCanvas, _ width: Double, _ height: Double) -> (Double, Double) {
        let column = anchor.rawValue % 3, row = anchor.rawValue / 3
        let x: Double
        switch column {
        case 0: x = 0
        case 1: x = (canvas.width - width) / 2
        default: x = canvas.width - width
        }
        let y: Double
        switch row {
        case 0: y = canvas.height - height
        case 1: y = (canvas.height - height) / 2
        default: y = 0
        }
        return (x, y)
    }

    // string.ReplaceLineEndings("\n").Split('\n'): CR LF, CR, LF, FF, NEL, LS and PS each end a line.
    static func lines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasReturn = false
        for scalar in text.unicodeScalars {
            let ends = [0x0A, 0x0D, 0x0C, 0x85, 0x2028, 0x2029].contains(scalar.value)
            if previousWasReturn && scalar.value == 0x0A {
                previousWasReturn = false
                continue
            }
            previousWasReturn = scalar.value == 0x0D
            if ends {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }
}
