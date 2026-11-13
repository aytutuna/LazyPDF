#if canImport(CoreText)
import CoreText
import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/WpfShaper.cs: Arabic and Hebrew runs shaped by the system, so the joined forms,
// ligatures and mark placement come from the font's own tables (AAT morx and kerx in Apple's fonts).

final class CoreTextShaper: Shaper {
    // Advances and positions come out in em fractions of this size, so they are already in 1/1000 em.
    private static let size: CGFloat = 1000

    private let lock = NSLock()
    private var cached: (file: FontFile, font: CTFont)?

    func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
        // Latin and the like stay with the engine's cmap shaper, and so does a left-to-right run of Arabic letters.
        guard rightToLeft, text.unicodeScalars.contains(where: { Self.isArabicOrHebrew($0.value) }),
              let ctFont = ctFont(font) else { return nil }

        // Direction marks are removed, as the engine draws them as nothing. Joiners stay, they decide the forms.
        var scalars: [Unicode.Scalar] = []
        var origin: [Int] = []
        var unitToScalar: [Int] = []
        var at = 0
        for scalar in text.unicodeScalars {
            let length = scalar.value > 0xFFFF ? 2 : 1
            if !Self.isDirectionControl(scalar.value) {
                for _ in 0..<length { unitToScalar.append(scalars.count) }
                scalars.append(scalar)
                origin.append(at)
            }
            at += length
        }
        if scalars.isEmpty { return [] }

        var sent = String.UnicodeScalarView()
        sent.append(contentsOf: scalars)
        // The run is one direction already, so it is forced to it and CoreText does no reordering of its own.
        // 1 is right to left and 2 marks an override.
        let direction = [NSNumber(value: Int(CTWritingDirection.rightToLeft.rawValue) | 2)]
        var attributes: [CFString: Any] = [kCTFontAttributeName: ctFont, kCTWritingDirectionAttributeName: direction]
        if let language { attributes[kCTLanguageAttributeName] = language }
        guard let attributed = CFAttributedStringCreate(nil, String(sent) as CFString, attributes as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }

        let postScriptName = CTFontCopyPostScriptName(ctFont) as String
        var result: [ShapedGlyph] = []
        var pen = 0.0
        for run in runs {
            // A font CoreText fell back to has glyph ids the embedded file does not have.
            let attributesOfRun = CTRunGetAttributes(run) as NSDictionary
            guard let object = attributesOfRun.object(forKey: kCTFontAttributeName) as AnyObject?,
                  CFGetTypeID(object) == CTFontGetTypeID(),
                  CTFontCopyPostScriptName(object as! CTFont) as String == postScriptName else { return nil }

            let count = CTRunGetGlyphCount(run)
            if count == 0 { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let whole = CFRange(location: 0, length: 0)
            CTRunGetGlyphs(run, whole, &glyphs)
            CTRunGetPositions(run, whole, &positions)
            CTRunGetAdvances(run, whole, &advances)
            CTRunGetStringIndices(run, whole, &indices)

            for i in 0..<count {
                guard indices[i] >= 0, indices[i] < unitToScalar.count else { return nil }
                var k = unitToScalar[indices[i]]
                let scalar = scalars[k]
                if Self.isInvisible(scalar.value) { continue }
                var glyph = glyphs[i]
                var advance = Double(advances[i].width)
                // Core has mirrored the brackets for the right-to-left run; CoreText would mirror them again.
                if scalar.properties.isBidiMirrored, scalar.value <= 0xFFFF {
                    var unit = UniChar(scalar.value)
                    var plain: CGGlyph = 0
                    if CTFontGetGlyphsForCharacters(ctFont, &unit, &plain, 1), plain != 0 {
                        glyph = plain
                        var width = CGSize.zero
                        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &plain, &width, 1)
                        advance = Double(width.width)
                    }
                }
                // A mark is part of the cluster of the letter it sits on.
                while k > 0, Self.isMark(scalars[k]) { k -= 1 }
                result.append(ShapedGlyph(glyph: Int(glyph), advance: advance, xOffset: Double(positions[i].x) - pen,
                                          yOffset: Double(positions[i].y), cluster: origin[k]))
                pen += advance
            }
        }
        return result
    }

    private func ctFont(_ file: FontFile) -> CTFont? {
        // One shaper is shared by every document being opened, and those opens run on separate threads.
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.file.collectionIndex == file.collectionIndex, cached.file.data == file.data { return cached.font }
        guard let faces = CTFontManagerCreateFontDescriptorsFromData(Data(file.data) as CFData) as? [CTFontDescriptor],
              file.collectionIndex >= 0, file.collectionIndex < faces.count else { return nil }
        let font = CTFontCreateWithFontDescriptor(faces[file.collectionIndex], Self.size, nil)
        cached = (file, font)
        return font
    }

    private static func isArabicOrHebrew(_ cp: UInt32) -> Bool {
        (cp >= 0x0590 && cp <= 0x06FF) || (cp >= 0x0750 && cp <= 0x077F) || (cp >= 0x08A0 && cp <= 0x08FF)
            || (cp >= 0xFB1D && cp <= 0xFDFF) || (cp >= 0xFE70 && cp <= 0xFEFF)
    }

    private static func isDirectionControl(_ cp: UInt32) -> Bool {
        cp == 0x200E || cp == 0x200F || cp == 0x061C || (cp >= 0x202A && cp <= 0x202E) || (cp >= 0x2066 && cp <= 0x2069)
    }

    // The joiners are kept for shaping but draw nothing.
    private static func isInvisible(_ cp: UInt32) -> Bool {
        (cp >= 0x200B && cp <= 0x200D) || (cp >= 0x2060 && cp <= 0x2064) || cp == 0xFEFF
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        return category == .nonspacingMark || category == .enclosingMark
    }
}
#endif
