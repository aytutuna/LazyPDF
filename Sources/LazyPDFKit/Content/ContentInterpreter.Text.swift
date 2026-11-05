import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentInterpreter.Text.cs: text positioning and showing (9.4).

extension ContentInterpreter {
    func syncText() {
        context.textMatrix = tm
        context.textLineMatrix = tlm
    }

    func setFont(_ op: ContentOperation) {
        let count = op.operands.count
        guard count >= 2, let name = op.operands[count - 2] as? PdfName, let size = op.operands[count - 1] as? PdfNumber else { return }
        state.fontSize = size.value
        if let dictionary = findResource("Font", name.value) as? PdfDictionary {
            state.font = font(dictionary)
        } else {
            state.font = fallback()
        }
    }

    // A viewer draws text in a missing font with something plain; the metrics are Helvetica's.
    private func fallback() -> PdfFont {
        if let known = fallbackFont { return known }
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Font")
        dictionary["Subtype"] = PdfName("Type1")
        dictionary["BaseFont"] = PdfName("Helvetica")
        let created = PdfFont.get(document, dictionary)
        fallbackFont = created
        return created
    }

    func moveText(_ op: ContentOperation) {
        switch op.operator {
        case "Td", "TD":
            guard let p = numbers(op, 2) else { return }
            if op.operator == "TD" { state.leading = -p[1] }
            tlm = PdfMatrix.translate(p[0], p[1]).multiply(tlm)
            tm = tlm
        case "Tm":
            guard let p = numbers(op, 6) else { return }
            tm = PdfMatrix(p[0], p[1], p[2], p[3], p[4], p[5])
            tlm = tm
        default:
            tlm = PdfMatrix.translate(0, -state.leading).multiply(tlm)
            tm = tlm
        }
        syncText()
    }

    func showText(_ op: ContentOperation) {
        let operands = op.operands
        guard let last = operands.last else { return }
        switch op.operator {
        case "Tj":
            if let s = last as? PdfString { show(s, 0) }
        case "'", "\"":
            let count = operands.count
            if op.operator == "\"" && count >= 3 {
                if let aw = operands[count - 3] as? PdfNumber { state.wordSpacing = aw.value }
                if let ac = operands[count - 2] as? PdfNumber { state.charSpacing = ac.value }
            }
            tlm = PdfMatrix.translate(0, -state.leading).multiply(tlm)
            tm = tlm
            syncText()
            if let line = last as? PdfString { show(line, op.operator == "\"" ? 1 : 0) }
        default:
            guard let array = last as? PdfArray else { break }
            for i in 0..<array.items.count {
                budget -= 1
                if budget < 0 {
                    isTruncated = true
                    break
                }
                if let text = array.items[i] as? PdfString {
                    show(text, i)
                } else if let adjust = array.items[i] as? PdfNumber, let font = state.font {
                    let shift = -adjust.value / 1000 * state.fontSize
                    tm = (font.isVertical ? PdfMatrix.translate(0, shift) : PdfMatrix.translate(shift * state.horizontalScale, 0)).multiply(tm)
                    syncText()
                }
            }
        }
    }

    private func show(_ text: PdfString, _ element: Int) {
        let state = self.state
        let font: PdfFont
        if let current = state.font {
            font = current
        } else {
            font = fallback()
            state.font = font
        }
        let bytes = text.bytes
        let scale = PdfMatrix(state.fontSize * state.horizontalScale, 0, 0, state.fontSize, 0, state.rise)
        var offset = 0
        while offset < bytes.count {
            budget -= 1
            if budget < 0 {
                isTruncated = true
                return
            }
            let (used, ch) = font.read(bytes[offset...])
            if used <= 0 { return }
            let width = ch.width / 1000
            var trm = scale.multiply(tm).multiply(state.ctm)
            let advance: Double
            if font.isVertical {
                trm = PdfMatrix.translate(-ch.originX / 1000, -ch.originY / 1000).multiply(trm)
                advance = ch.verticalAdvance / 1000 * state.fontSize + state.charSpacing + (ch.isSpace ? state.wordSpacing : 0)
            } else {
                advance = (width * state.fontSize + state.charSpacing + (ch.isSpace ? state.wordSpacing : 0)) * state.horizontalScale
            }
            let box = trm.transform(PdfRect(0, font.descent / 1000, width, font.ascent / 1000))
            visitor.showGlyph(context, GlyphInfo(ch, font, trm, box, advance, element, offset))
            tm = (font.isVertical ? PdfMatrix.translate(0, advance) : PdfMatrix.translate(advance, 0)).multiply(tm)
            syncText()
            offset += used
        }
    }
}
