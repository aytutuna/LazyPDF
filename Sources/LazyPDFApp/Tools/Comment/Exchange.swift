import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/Exchange.cs: comments in and out of the file as FDF or XFDF, and burned into the
// pages.

/// What an export wrote: the file, how many comments are in it and how many things XFDF has no room for.
public struct Exported {
    public let data: [UInt8]
    public let count: Int
    public let left: Int
}

public enum Exchange {
    public static func isXfdf(_ path: String) -> Bool {
        (path as NSString).pathExtension.caseInsensitiveCompare("xfdf") == .orderedSame
    }

    public static func export(_ document: PdfDocument, _ pdfName: String?, xfdf: Bool) throws -> Exported {
        let fdf = try PdfFdf.export(document, pdfName)
        let left = xfdf ? fdf.annotations.filter { isPicture($0.dictionary) }.count : 0
        let data = xfdf ? try PdfXfdf.write(fdf) : try PdfFdf.write(fdf)
        let count = fdf.annotations.filter { subtype($0.dictionary) != "Popup" }.count
        return Exported(data: data, count: count, left: left)
    }

    private static func subtype(_ d: PdfDictionary) -> String? {
        (d["Subtype"] as? PdfName)?.value
    }

    // XFDF keeps no attachment data and no image of a picture stamp.
    private static func isPicture(_ d: PdfDictionary) -> Bool {
        subtype(d) == "FileAttachment" || (subtype(d) == "Stamp" && (d["Name"] as? PdfName)?.value == "Image")
    }

    public static func `import`(_ document: PdfDocument, _ data: [UInt8], xfdf: Bool, _ fonts: FontSource?) throws -> FdfImportResult {
        let fdf = xfdf ? try PdfXfdf.read(data) : try PdfFdf.read(data)
        return try PdfFdf.import(document, fdf, fonts)
    }

    /// The marks that flattening would burn in.
    public static func flattenable(_ document: PdfDocument) -> Int {
        PdfAnnotations.readAll(document).filter {
            PdfAnnotationFlattener.defaultTypes.contains($0.type) && $0.hasAppearance
                && !$0.flags.contains(.hidden) && !$0.flags.contains(.noView)
        }.count
    }

    public static func flatten(_ document: PdfDocument, _ token: CancelToken) throws -> Int {
        var burned = 0
        for page in document.pages {
            try token.throwIfCancelled()
            burned += try PdfAnnotationFlattener.flatten(document, page)
        }
        return burned
    }

    /// Whether marks may be added: the permissions allow annotating, and a certification, if there is one, allows it too.
    public static func canComment(_ document: PdfDocument) -> Bool {
        PdfAnnotations.canAnnotate(document) && (!document.isCertified || certifiedLevel(document) >= 3)
    }

    // The /DocMDP permission of the certification (12.8.2.2); 2 when the file does not say.
    private static func certifiedLevel(_ document: PdfDocument) -> Int {
        var level = 2
        let signature = document.resolve(document.dict(document.catalog, "Perms")?["DocMDP"]) as? PdfDictionary
        guard let references = document.array(signature, "Reference") else { return level }
        for item in references.items {
            if let reference = document.resolve(item) as? PdfDictionary, document.name(reference, "TransformMethod") == "DocMDP",
               let parameters = document.dict(reference, "TransformParams"), let p = document.integer(parameters, "P") {
                level = p
            }
        }
        return level
    }
}
