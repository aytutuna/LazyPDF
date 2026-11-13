import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAConverter.Tags.cs. Level A: the structure the file already has is kept; an
// untagged file with a language is tagged by the accessibility tagger.
extension PdfAConversionRun {
    /// Returns what would let the file be tagged here, when it is not.
    func prepareTags() throws -> String? {
        if document.dict(document.catalog, "StructTreeRoot") == nil {
            // The language of the text cannot be guessed; the tagger writes none, so the file has to name it already.
            if DotNetText.isNullOrWhiteSpace(PdfText.read(document, document.catalog, "Lang")) { return PdfAText.setLanguageToTag }
            let result = try AutoTagger.tag(document)
            if result.pages > 0 { changed(PdfAText.tagged(result.pages)) }
        } else if !document.isTagged && document.bool(document.dict(document.catalog, "MarkInfo"), "Suspects") != true,
                  let tree = StructureTree.read(document), !tree.roots.isEmpty {
            var info = document.dict(document.catalog, "MarkInfo")
            if info == nil {
                info = PdfDictionary()
                document.catalog["MarkInfo"] = info
            }
            info?["Marked"] = PdfBoolean(true)
            changed(PdfAText.marked)
        }
        return nil
    }
}
