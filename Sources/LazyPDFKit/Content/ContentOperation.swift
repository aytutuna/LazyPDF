import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentOperation.cs: one operator of a content stream with its operands
// (ISO 32000-1 7.8.2). `start` and `end` are byte positions in the data it was parsed from, from the first operand
// to just past the operator, so an editor can cut or replace exactly this operation.

public final class ContentOperation: CustomStringConvertible {
    public let `operator`: String
    public let operands: [PdfObject]
    public let start: Int
    public let end: Int

    /// For `BI`: the image, whose dictionary and data are not operands. Nil otherwise.
    public let image: InlineImage?

    public init(_ name: String, _ operands: [PdfObject], _ start: Int, _ end: Int, _ image: InlineImage? = nil) {
        self.operator = name
        self.operands = operands
        self.start = start
        self.end = end
        self.image = image
    }

    /// Operand `index` as a number; nil when it is missing or not one.
    public func number(_ index: Int) -> Double? {
        guard index >= 0, index < operands.count, let n = operands[index] as? PdfNumber else { return nil }
        return n.value
    }

    public var description: String {
        let text = operands.map { $0.description }.joined(separator: " ") + " " + self.operator
        return String(text.drop(while: { $0 == " " }))
    }
}

/// The dictionary and data of a `BI ... ID ... EI` image (8.9.7). The dictionary keeps the abbreviations it was
/// written with; `data` is the bytes between ID and EI, filters still applied.
public final class InlineImage {
    private static let keys: [String: String] = [
        "BPC": "BitsPerComponent", "CS": "ColorSpace", "D": "Decode", "DP": "DecodeParms",
        "F": "Filter", "H": "Height", "IM": "ImageMask", "I": "Interpolate", "W": "Width",
    ]

    public let dictionary: PdfDictionary
    public let data: [UInt8]

    public init(_ dictionary: PdfDictionary, _ data: [UInt8]) {
        self.dictionary = dictionary
        self.data = data
    }

    /// The dictionary with full key names, the form the filters and image decoder read. Colour space names that are
    /// not device spaces are looked up with `colorSpace` (the page's /ColorSpace resources); the other
    /// abbreviations are left to those readers.
    public func expanded(_ colorSpace: ((String) -> PdfObject?)? = nil) -> PdfDictionary {
        let result = PdfDictionary()
        for (key, value) in dictionary.entries {
            let full = Self.keys[key] ?? key
            if full == "ColorSpace", let name = value as? PdfName, let found = colorSpace?(name.value) {
                result[full] = found
            } else {
                result[full] = value
            }
        }
        return result
    }
}
