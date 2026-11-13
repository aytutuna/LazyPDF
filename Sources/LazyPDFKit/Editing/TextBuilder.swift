import Foundation

// Twin of windows/LazyPDF.Core/Editing/TextBuilder.cs: turns new text into pieces in the font of the text it replaces,
// or a stand-in where that font lacks the glyphs.

/// A font that stood in for the one in the file because that one had no glyph for some characters.
/// `original` is the base font name of the font in the file, `replacement` the family the stand-in was asked for,
/// `characters` the characters it draws, `embedded` whether the stand-in is embedded in the file (else it is a Standard 14 font).
public struct FontSubstitution: Equatable {
    public let original: String
    public let replacement: String
    public let characters: String
    public let embedded: Bool

    public init(_ original: String, _ replacement: String, _ characters: String, _ embedded: Bool) {
        self.original = original
        self.replacement = replacement
        self.characters = characters
        self.embedded = embedded
    }
}

/// string.Concat(missing.Select(char.ConvertFromUtf32)): the characters a font lacks, for the message.
func lettersOf(_ codePoints: [Int]) -> String {
    var text = String.UnicodeScalarView()
    for codePoint in codePoints {
        text.append(UInt32(exactly: codePoint).flatMap { Unicode.Scalar($0) } ?? "\u{FFFD}")
    }
    return String(text)
}

/// One character of new text, ready for a show operator.
struct EditPiece {
    var text = ""
    var bytes: [UInt8] = []

    /// How far it moves the text position, in text space units (character and word spacing and horizontal scaling in).
    var advance = 0.0

    /// The resource name of the stand-in font; nil for the font in force.
    var font: String?

    /// The stand-in font the bytes were made in; its pieces are shaped together when the line is written.
    var draw: PdfDrawFont?

    var isSpace = false

    /// The piece is a whole shaped run (see `TextBuilder.shape`): `text` is its logical text and `bytes` is not used.
    var isShaped = false

    /// The width in em before spacing and scaling, and whether word spacing applies to it (a single byte code 32).
    var em = 0.0
    var code32 = false

    /// A space the font has no glyph for is a move instead, in thousandths of the size.
    var shift: Double?
}

final class TextBuilder {
    private struct StandKey: Hashable {
        let unit: ContentUnit
        let font: ObjectIdentifier
    }

    private let document: PdfDocument
    private let batch: EditBatch
    private let fonts: FontSource?
    private var codecs: [ObjectIdentifier: FontCodec] = [:]
    private var codecOrder: [FontCodec] = []
    private var stands: [StandKey: (draw: PdfDrawFont, name: String, covered: String)] = [:]
    private var made: [(info: FontSubstitution, place: Place, name: String)] = []

    init(_ document: PdfDocument, _ batch: EditBatch, _ fonts: FontSource?) {
        self.document = document
        self.batch = batch
        self.fonts = fonts
    }

    /// The stand-ins whose font is still in the batch; one taken back with its edit is not reported.
    var substitutions: [FontSubstitution] { made.filter { batch.hasResource($0.place, $0.name) }.map { $0.info } }

    func codec(_ font: PdfFont) -> FontCodec {
        if let known = codecs[ObjectIdentifier(font)] { return known }
        let created = FontCodec(document, font)
        codecs[ObjectIdentifier(font)] = created
        codecOrder.append(created)
        return created
    }

    func writeAdditions() {
        for codec in codecOrder { codec.writeAdditions() }
    }

    /// Whether every character of `text` can be shown in `font` as it is.
    func canShow(_ font: PdfFont, _ text: String) -> Bool {
        Self.runes(text).allSatisfy { $0 == " " || codec(font).tryGet($0) != nil }
    }

    private static func runes(_ text: String) -> [String] {
        text.unicodeScalars.filter { $0.value >= 0x20 || $0.value == 9 }.map { $0.value == 9 ? " " : String($0) }
    }

    /// The pieces of `text` in the font of `anchor`; throws `EditConflictException` with the reason when the text cannot be shown.
    func build(_ place: Place, _ anchor: EditGlyph, _ text: String) throws -> [EditPiece] {
        let runes = Self.runes(text)
        let fontCodec = codec(anchor.font)
        var pieces = [EditPiece?](repeating: nil, count: runes.count)
        var missing: [Int] = []
        let bidi = fonts != nil && Scripts.needsBidi(text)
        for i in 0..<runes.count {
            let r = runes[i]
            if let code = fontCodec.tryGet(r) ?? fontCodec.tryExtend(r) {
                pieces[i] = Self.anchored(anchor, r, code)
            } else if r == " " {
                pieces[i] = EditPiece(text: r, advance: 0.25 * anchor.fontSize * anchor.scale, isSpace: true, em: 0.25, shift: -250)
            } else {
                missing.append(i)
            }
        }
        if bidi { try shapeInStandIn(place, anchor, runes, &pieces, missing) }
        else if !missing.isEmpty { try substitute(place, anchor, runes, &pieces, missing) }
        return pieces.compactMap { $0 }
    }

    // The font in the file draws characters one by one in logical order, so text with right-to-left characters goes whole
    // into a stand-in that items shapes. When no stand-in can be had the pieces stay as they are, unless a glyph is missing anyway.
    private func shapeInStandIn(_ place: Place, _ anchor: EditGlyph, _ runes: [String], _ pieces: inout [EditPiece?], _ missing: [Int]) throws {
        var all = [EditPiece?](repeating: nil, count: runes.count)
        do {
            try substitute(place, anchor, runes, &all, Array(0..<runes.count))
        } catch let error as EditConflictException {
            if missing.isEmpty { return }
            throw error
        }
        pieces = all
    }

    /// The pieces of `text` all in a font chosen for the job, drawn at `size`.
    static func buildWith(_ draw: PdfDrawFont, _ name: String, _ anchor: EditGlyph, _ text: String, _ size: Double) -> [EditPiece] {
        runes(text).map { r in
            EditPiece(text: r, bytes: draw.encode(r),
                      advance: (draw.width(r, 1000) / 1000 * size + anchor.charSpacing + (r == " " && !draw.isEmbedded ? anchor.wordSpacing : 0)) * anchor.scale,
                      font: name, draw: draw, isSpace: r == " ", em: draw.width(r, 1000) / 1000, code32: r == " " && !draw.isEmbedded)
        }
    }

    private static func anchored(_ anchor: EditGlyph, _ text: String, _ code: FontCode) -> EditPiece {
        EditPiece(text: text, bytes: code.bytes,
                  advance: (code.width / 1000 * anchor.fontSize + anchor.charSpacing + (code.isSpace ? anchor.wordSpacing : 0)) * anchor.scale,
                  isSpace: text == " ", em: code.width / 1000, code32: code.isSpace)
    }

    private func substitute(_ place: Place, _ anchor: EditGlyph, _ runes: [String], _ pieces: inout [EditPiece?], _ missing: [Int]) throws {
        guard let fonts else { throw EditConflictException(EditingText.noFont) }
        let state = place.states.at(anchor.op)
        if state.font == nil { throw EditConflictException(EditingText.fontSetOutside) }
        // The whole text goes to the embedder: joined forms depend on the neighbours, so distinct characters would miss them.
        let needed = missing.map { runes[$0] }.joined()
        let key = StandKey(unit: place.unit, font: ObjectIdentifier(anchor.font))
        // An edit taken back removes its resources; a stand-in named by one is no longer there.
        var stand: (draw: PdfDrawFont, name: String, covered: String)?
        if let found = stands[key], batch.hasResource(place, found.name) { stand = found }
        if let known = stand, known.covered.range(of: needed, options: .literal) != nil {
            // The stand-in already has them.
        } else {
            let covered = (stand?.covered ?? "") + needed
            let (families, style) = FontMatch.for(anchor.font)
            let embedder = PdfFontEmbedder(document, fonts)
            var draw: PdfDrawFont?
            var family = families[0]
            for candidate in families {
                draw = try embedder.add(candidate, style, [covered], embed: anchor.font.isEmbedded)
                family = candidate
                if draw != nil { break }
            }
            guard let drawn = draw else { throw EditConflictException(EditingText.noFont) }
            if !drawn.missing.isEmpty { throw EditConflictException(EditingText.noGlyphs(lettersOf(drawn.missing))) }
            guard let name = batch.addResource(place, "Font", drawn.reference) else { throw EditConflictException(EditingText.sharedForm) }
            stand = (drawn, name, covered)
            stands[key] = stand
            var seen = Set<UInt32>()
            let distinct = missing.map { runes[$0] }.filter { r in r.unicodeScalars.first.map { seen.insert($0.value).inserted } ?? false }.joined()
            made.append((FontSubstitution(anchor.font.name, family, distinct, drawn.isEmbedded), place, name))
        }
        guard let current = stand else { return }
        for i in missing {
            let r = runes[i]
            let width = current.draw.width(r, 1000)
            pieces[i] = EditPiece(text: r, bytes: current.draw.encode(r),
                                  advance: (width / 1000 * anchor.fontSize + anchor.charSpacing + (r == " " && !current.draw.isEmbedded ? anchor.wordSpacing : 0)) * anchor.scale,
                                  font: current.name, draw: current.draw, isSpace: r == " ", em: width / 1000, code32: r == " " && !current.draw.isEmbedded)
        }
    }

    /// Joins consecutive pieces of one stand-in font with right-to-left characters into one piece, so that it is shaped and
    /// written in display order and measured by what the shaper makes of it. `rightToLeft` is the direction of the paragraph
    /// the line belongs to; a line that would start the other way gets a direction mark. Pieces with no such text stay as they are.
    static func shape(_ pieces: [EditPiece], _ anchor: EditGlyph, size: Double? = nil, rightToLeft: Bool? = nil) -> [EditPiece] {
        let em = size ?? anchor.fontSize
        var result: [EditPiece] = []
        var i = 0
        while i < pieces.count {
            if let draw = pieces[i].draw, pieces[i].shift == nil, !pieces[i].isShaped {
                var end = i + 1
                while end < pieces.count, pieces[end].draw === draw, pieces[end].font == pieces[i].font, pieces[end].shift == nil, !pieces[end].isShaped { end += 1 }
                var text = pieces[i..<end].map { $0.text }.joined()
                if Scripts.needsBidi(text), draw.isEmbedded {
                    if let rtl = rightToLeft, draw.isRightToLeft(text) != rtl { text = (rtl ? "\u{200F}" : "\u{200E}") + text }
                    if let line = draw.shaped(text) {
                        var piece = EditPiece(text: text, advance: (line.width / 1000 * em + anchor.charSpacing * Double(line.glyphs.count)) * anchor.scale,
                                              font: pieces[i].font, draw: draw, em: line.width / 1000)
                        piece.isShaped = true
                        result.append(piece)
                        i = end
                        continue
                    }
                }
            }
            result.append(pieces[i])
            i += 1
        }
        return result
    }

    /// The pieces as show items. A stand-in font is selected before its characters and the font in
    /// force at `at` selected again after them; `before` and `after` go round the whole text.
    static func items(_ place: Place, _ at: EditGlyph, _ pieces: [EditPiece], shift: Double = 0, before: [UInt8]? = nil, after: [UInt8]? = nil,
                      size: Double? = nil, current: ContentOperation? = nil) throws -> [ShowItem] {
        var items: [ShowItem] = []
        if let before, !before.isEmpty { items.append(ShowOps(before)) }
        if shift != 0 { items.append(ShowShift(-shift)) }
        var run: [UInt8] = []
        var font: String?
        func flush() {
            if !run.isEmpty { items.append(ShowText(run)) }
            run.removeAll()
        }
        func select(_ next: String?) throws {
            if next == font { return }
            flush()
            if let next {
                items.append(ShowOps(ContentWriter().font(next, size ?? at.fontSize).toArray()))
            } else if let restore = current ?? place.states.at(at.op).font {
                items.append(ShowOps(ContentWriter().add(restore).toArray()))
            } else {
                throw EditConflictException(EditingText.fontSetOutside)
            }
            font = next
        }
        for piece in pieces {
            if let move = piece.shift {
                try select(nil)
                flush()
                items.append(ShowShift(move))
                continue
            }
            try select(piece.font)
            if piece.isShaped, let draw = piece.draw {
                flush()
                items.append(ShowOps(ContentWriter().show(draw, piece.text, size ?? at.fontSize).toArray()))
                continue
            }
            run.append(contentsOf: piece.bytes)
        }
        try select(nil)
        flush()
        if let after, !after.isEmpty { items.append(ShowOps(after)) }
        return items
    }
}
