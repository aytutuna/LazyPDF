import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/StampDraft.cs: what the form describes, one spec of the engine's and the picture file
// it names, if any.

public struct StampDraft {
    public var watermark: WatermarkSpec?
    public var background: BackgroundSpec?
    public var headerFooter: HeaderFooterSpec?
    public var picture: [UInt8]?

    public init(watermark: WatermarkSpec? = nil, background: BackgroundSpec? = nil, headerFooter: HeaderFooterSpec? = nil, picture: [UInt8]? = nil) {
        self.watermark = watermark
        self.background = background
        self.headerFooter = headerFooter
        self.picture = picture
    }

    public var kind: StampKind {
        if watermark != nil { return .watermark }
        if background != nil { return .background }
        return headerFooter?.bates != nil ? .bates : .headerFooter
    }

    public var addText: String {
        switch kind {
        case .watermark: return L10n.t("Add watermark")
        case .background: return L10n.t("Add background")
        case .bates: return L10n.t("Add Bates numbers")
        case .headerFooter: return L10n.t("Add header and footer")
        }
    }

    /// What is missing before the engine can draw it; nil when nothing is.
    public var problem: String? {
        if let mark = watermark {
            let blank = (mark.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return blank && picture == nil ? StampsText.needsContent : nil
        }
        if let back = background { return back.color == nil && picture == nil ? StampsText.needsContent : nil }
        guard let spec = headerFooter else { return nil }
        if spec.bates != nil { return nil }
        let slots = [spec.header.left, spec.header.center, spec.header.right, spec.footer.left, spec.footer.center, spec.footer.right]
        return slots.allSatisfy(\.isEmpty) ? L10n.t("Type the text for at least one place.") : nil
    }

    /// Adds the stamp, or replaces run `replace` with it. The caller commits. Throws `InvalidOperationException` when no font
    /// can draw the text and `InvalidDataException` when the picture cannot be read.
    public func apply(_ document: PdfDocument, fonts: FontSource?, codec: ImageCodec?, replace: Int?) throws -> StampRun {
        let stamper = PdfStamper(document, fonts)
        if var mark = watermark {
            if picture != nil {
                mark.text = nil
                mark.image = try addPicture(document, codec)
            }
            if let replace { return try stamper.update(replace, mark) }
            return try stamper.addWatermark(mark)
        }
        if var back = background {
            if picture != nil { back.image = try addPicture(document, codec) }
            if let replace { return try stamper.update(replace, back) }
            return try stamper.addBackground(back)
        }
        guard let bands = headerFooter else { throw InvalidOperationException(StampsText.needsContent) }
        if let replace { return try stamper.update(replace, bands) }
        return try stamper.addHeaderFooter(bands)
    }

    private func addPicture(_ document: PdfDocument, _ codec: ImageCodec?) throws -> PdfImage {
        guard let added = try PdfImageWriter.addPicture(document, picture ?? [], codec) else { throw InvalidDataException("The picture cannot be read.") }
        return added
    }
}
