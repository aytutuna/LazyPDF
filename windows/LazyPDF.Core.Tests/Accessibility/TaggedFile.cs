using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

/// <summary>A small tagged one-page file made by hand: Document with H1, P and Figure, one parent tree array.</summary>
internal static class TaggedFile
{
    public const string Content =
        "/H1 <</MCID 0>> BDC BT /F2 18 Tf 72 700 Td (Head) Tj ET EMC\n" +
        "/P <</MCID 1>> BDC BT /F1 11 Tf 72 670 Td (Body text) Tj ET EMC\n" +
        "/Figure <</MCID 2>> BDC q 50 0 0 50 72 600 cm /Im1 Do Q EMC\n";

    /// <summary>The structure objects 8 to 13; a test may replace or add entries before the file is written.</summary>
    public static SortedDictionary<int, string> Objects() => new()
    {
        [8] = "<</Type /StructTreeRoot /K 9 0 R /ParentTree 13 0 R /ParentTreeNextKey 1 /RoleMap <</Heading /H1 /Weird /Nope>> /ClassMap <</Fancy <</O /Layout>>>>>>",
        [9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R]>>",
        [10] = "<</Type /StructElem /S /H1 /P 9 0 R /Pg 3 0 R /K 0 /T (Head) /Lang (tr) /A <</O /Layout /Placement /Block>> /C /Fancy>>",
        [11] = "<</Type /StructElem /S /P /P 9 0 R /Pg 3 0 R /K 1 /ActualText (Body text)>>",
        [12] = "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2 /Alt (A picture)>>",
        [13] = "<</Nums [0 [10 0 R 11 0 R 12 0 R]]>>",
    };

    public static byte[] Build(Action<SortedDictionary<int, string>>? edit = null, string catalog = "/Lang (en-US)", string content = Content)
    {
        var objects = Objects();
        edit?.Invoke(objects);
        return AccessKit.Build(1, _ => content, $"/StructTreeRoot 8 0 R /MarkInfo <</Marked true>> {catalog}", "/StructParents 0 /Tabs /S", pdf =>
        {
            foreach (var (number, body) in objects) pdf.Obj(number, body);
        });
    }

    public static PdfDocument Open(Action<SortedDictionary<int, string>>? edit = null, string catalog = "/Lang (en-US)") =>
        PdfDocument.Open(Build(edit, catalog));
}
