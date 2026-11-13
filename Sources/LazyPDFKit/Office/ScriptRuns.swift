// Twin of windows/LazyPDF.Core/Office/ScriptRuns.cs: cuts text into the stretches Word and PowerPoint format apart: Hebrew and
// Arabic letters (complex script) and the rest.

enum ScriptRuns {
    /// The stretches of `text` in order. Digits, spaces and punctuation go with the letters before them, or with the first
    /// letter after them when the text starts with some.
    static func split(_ text: String) -> [(text: String, complex: Bool)] {
        let scalars = Array(text.unicodeScalars)
        let kinds = scalars.map { kind(Int($0.value)) }
        guard let first = kinds.compactMap({ $0 }).first, scalars.contains(where: { Scripts.isHebrew(Int($0.value)) || Scripts.isArabic(Int($0.value)) }) else {
            return [(text, false)]
        }
        var parts: [(text: String, complex: Bool)] = []
        var current = first
        var piece = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            let k = kinds[i] ?? current
            if k != current && !piece.isEmpty {
                parts.append((String(piece), current == 1))
                piece = String.UnicodeScalarView()
            }
            current = k
            piece.append(scalar)
        }
        parts.append((String(piece), current == 1))
        return parts
    }

    /// Whether the first letter of the text is a Hebrew or Arabic one; nil when there is no letter.
    static func startsComplex(_ text: String) -> Bool? {
        for scalar in text.unicodeScalars {
            if let k = kind(Int(scalar.value)) { return k == 1 }
        }
        return nil
    }

    // 1 for a complex-script letter, 0 for a letter of another script, nil for a character that has no script of its own.
    private static func kind(_ cp: Int) -> Int? {
        if Scripts.isHebrew(cp) || Scripts.isArabic(cp) { return 1 }
        let neutral = cp < 0x41 || (cp >= 0x5B && cp <= 0x60) || (cp >= 0x7B && cp <= 0xBF) || (cp >= 0x2000 && cp <= 0x2BFF)
            || (cp >= 0xFE00 && cp <= 0xFE0F) || cp == 0x200F
        return neutral ? nil : 0
    }
}
