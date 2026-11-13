namespace LazyPDF.Core;

// Level A: the structure the file already has is kept; an untagged file with a language is tagged by the accessibility tagger.
internal sealed partial class PdfAConversionRun
{
    // Returns what would let the file be tagged here, when it is not.
    private string? PrepareTags()
    {
        if (_doc.Dict(_doc.Catalog, "StructTreeRoot") is null)
        {
            // The language of the text cannot be guessed; the tagger writes none, so the file has to name it already.
            if (string.IsNullOrWhiteSpace(PdfText.Read(_doc, _doc.Catalog, "Lang"))) return PdfAText.SetLanguageToTag;
            var result = AutoTagger.Tag(_doc);
            if (result.Pages > 0) Changed(PdfAText.Tagged(result.Pages));
        }
        else if (!_doc.IsTagged && _doc.Bool(_doc.Dict(_doc.Catalog, "MarkInfo"), "Suspects") != true && StructureTree.Read(_doc) is { Roots.Count: > 0 })
        {
            var info = _doc.Dict(_doc.Catalog, "MarkInfo");
            if (info is null) _doc.Catalog["MarkInfo"] = info = new PdfDictionary();
            info["Marked"] = new PdfBoolean(true);
            Changed(PdfAText.Marked);
        }
        return null;
    }
}
