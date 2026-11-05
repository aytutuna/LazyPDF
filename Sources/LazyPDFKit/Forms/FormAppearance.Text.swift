import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormAppearance.Text.cs: the appearance of text, comb and choice fields.

extension FormAppearance {
    private static let selection: [Double] = [0.6, 0.75, 0.85]

    // A comb field of more cells than this draws no further dividers: a crafted /MaxLen cannot make the loop run for ever.
    private static let maxDividers = 100_000

    func textField(_ field: FormField, _ look: Look, _ font: FormFont, _ display: String) -> PdfStream {
        let c = newCanvas(look)
        frame(c, look, ellipse: false)
        var text = field.has(.password) ? Self.bullets(font, display) : display
        if text.isEmpty { return finish(c, look) }

        let inset = look.inset, pad = inset + 1
        let availableWidth = max(1, look.width - 2 * pad)
        let lineFit = (look.height - 2 * inset - 2) / (font.ascent - font.descent)

        if field.has(.comb) && field.maxLength > 0 && !field.has(.multiline) {
            comb(c, field, look, font, text)
        } else if field.has(.multiline) {
            let (size, lines) = multiline(font, text, look, availableWidth, pad)
            var y = look.height - pad - font.ascent * size
            var placed: [(text: String, x: Double, y: Double)] = []
            for line in lines {
                placed.append((line, alignedX(look.alignment, look.width, pad, font.width(line, size)), y))
                y -= font.lineHeight(size)
            }
            showLines(c, look, font, size, placed)
        } else {
            text = lineEndingsToSpaces(text)
            var size = look.fontSize > 0 ? look.fontSize : min(Self.maxSize, max(Self.minAutoSize, lineFit))
            var width = font.width(text, size)
            if look.fontSize <= 0 && width > availableWidth { size = max(Self.minAutoSize, size * availableWidth / width) }
            width = font.width(text, size)
            let baseline = (look.height - font.lineHeight(size)) / 2 - font.descent * size
            showLines(c, look, font, size, [(text, alignedX(look.alignment, look.width, pad, width), baseline)])
        }
        return finish(c, look)
    }

    // string.ReplaceLineEndings(" "): CR LF is one ending, and CR, LF, FF, NEL, LS and PS each are.
    private func lineEndingsToSpaces(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 10 && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = v == 13
            if v == 10 || v == 13 || v == 12 || v == 0x85 || v == 0x2028 || v == 0x2029 {
                result.append(" ")
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private func alignedX(_ alignment: Int, _ width: Double, _ pad: Double, _ textWidth: Double) -> Double {
        switch alignment {
        case 1: return (width - textWidth) / 2
        case 2: return width - pad - textWidth
        default: return pad
        }
    }

    // 12.7.4.3: with the size 0 a multiline field starts at 12 points and shrinks until the text fits.
    private func multiline(_ font: FormFont, _ text: String, _ look: Look, _ availableWidth: Double, _ pad: Double) -> (size: Double, lines: [String]) {
        let height = look.height - 2 * pad
        if look.fontSize > 0 { return (look.fontSize, font.wrap(text, look.fontSize, availableWidth)) }
        var size = Self.maxAutoMultiline
        while true {
            let lines = font.wrap(text, size, availableWidth)
            if size <= Self.minAutoSize || Double(lines.count) * font.lineHeight(size) <= height { return (size, lines) }
            size -= 0.5
        }
    }

    private func comb(_ c: AppearanceCanvas, _ field: FormField, _ look: Look, _ font: FormFont, _ text: String) {
        let chars = text.unicodeScalars.prefix(field.maxLength).map { String($0) }
        let inset = look.inset
        let cell = (look.width - 2 * inset) / Double(field.maxLength)
        var size = look.fontSize
        if size <= 0 {
            size = min(Self.maxSize, max(Self.minAutoSize, (look.height - 2 * inset - 2) / (font.ascent - font.descent)))
            let widest = chars.map { font.width($0, 1) }.max() ?? 0
            if widest * size > cell - 1 { size = max(Self.minAutoSize, (cell - 1) / widest) }
        }
        if let borderColor = look.borderColor, look.borderWidth > 0, c.color(borderColor, stroke: true) {
            c.stroke(look.borderWidth, nil)
            for i in 1..<max(1, min(field.maxLength, Self.maxDividers)) {
                c.move(inset + cell * Double(i), 0).line(inset + cell * Double(i), look.height)
            }
            c.w.stroke()
        }
        let baseline = (look.height - font.lineHeight(size)) / 2 - font.descent * size
        // A short text sits at the start, in the middle or at the end of the cells as /Q says.
        let offset = Double(field.maxLength - chars.count) * cell * Double(look.alignment) / 2.0
        var placed: [(text: String, x: Double, y: Double)] = []
        for i in 0..<chars.count {
            placed.append((chars[i], inset + offset + cell * Double(i) + (cell - font.width(chars[i], size)) / 2, baseline))
        }
        showLines(c, look, font, size, placed)
    }

    func listBox(_ field: FormField, _ look: Look, _ font: FormFont) -> PdfStream {
        let c = newCanvas(look)
        frame(c, look, ellipse: false)
        let inset = look.inset, pad = inset + 1
        let size = look.fontSize > 0 ? look.fontSize : Self.maxAutoMultiline
        let row = font.lineHeight(size)
        let visible = max(1, Int(saturating32: (look.height - 2 * pad) / row))
        let selected = selectedIndexes(field)
        var top = min(max(document.integer(field.dictionary, "TI") ?? 0, 0), max(0, field.options.count - 1))
        if let first = selected.first {
            if first < top {
                top = first
            } else if first >= top + visible {
                top = first - visible + 1
            }
        }
        top = min(max(top, 0), max(0, field.options.count - visible))
        if top > 0 {
            field.dictionary["TI"] = PdfNumber(top)
        } else {
            field.dictionary.remove("TI")
        }

        var lines: [(text: String, x: Double, y: Double)] = []
        var i = top
        while i < field.options.count && i < top + visible + 1 {
            let rowTop = look.height - pad - Double(i - top) * row
            if selected.contains(i) && c.color(Self.selection, stroke: false) {
                c.w.rect(inset, rowTop - row, look.width - 2 * inset, row).fill()
            }
            let display = field.options[i].display
            lines.append((display, alignedX(look.alignment, look.width, pad, font.width(display, size)), rowTop - font.ascent * size))
            i += 1
        }
        showLines(c, look, font, size, lines)
        return finish(c, look)
    }

    // /I names the selected items by index; without it the values in /V are looked up in /Opt.
    func selectedIndexes(_ field: FormField) -> [Int] {
        var chosen: [Int] = []
        if let indexes = document.array(field.dictionary, "I") {
            for item in indexes.items {
                if let number = document.resolve(item) as? PdfNumber, let i = number.integer, i >= 0, i < field.options.count { chosen.append(i) }
            }
        } else {
            for i in 0..<field.options.count where field.selected.containsOrdinal(field.options[i].export) { chosen.append(i) }
        }
        chosen.sort()
        return chosen
    }
}
