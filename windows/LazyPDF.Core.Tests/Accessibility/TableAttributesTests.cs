using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class TableAttributesTests
{
    private static (PdfDocument Document, StructureTree Tree, StructElement Table, StructElement[] Rows) Grid()
    {
        var document = PdfDocument.Open(AccessKit.Build(1, _ => ""));
        var tree = StructureTree.Create(document);
        var root = new StructElement("Document");
        tree.Add(null, root);
        var table = new StructElement("Table");
        tree.Add(root, table);
        var rows = new StructElement[2];
        for (int r = 0; r < rows.Length; r++)
        {
            rows[r] = new StructElement("TR");
            tree.Add(table, rows[r]);
            for (int c = 0; c < 2; c++) tree.Add(rows[r], new StructElement("TD"));
        }
        return (document, tree, table, rows);
    }

    private static PdfDictionary Dict(string owner, params (string Key, PdfObject Value)[] more)
    {
        var d = new PdfDictionary { ["O"] = new PdfName(owner) };
        foreach (var (key, value) in more) d[key] = value;
        return d;
    }

    private static PdfName Name(string value) => new(value);

    private static PdfNumber Num(int value) => new(value);

    private static PdfArray Strings(params string[] values) => new(values.Select(v => (PdfObject)PdfText.ToObject(v)).ToList());

    [Fact]
    public void ReadsOneDictionary()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        cell.Dictionary["A"] = Dict("Table", ("Scope", Name("Both")), ("RowSpan", Num(2)), ("ColSpan", Num(3)), ("Headers", Strings("a", "b")));

        var attributes = tree.GetTableAttributes(cell);
        Assert.Equal(TableScope.Both, attributes.Scope);
        Assert.Equal(2, attributes.RowSpan);
        Assert.Equal(3, attributes.ColSpan);
        Assert.Equal(["a", "b"], attributes.Headers);
    }

    [Fact]
    public void ReadsAnArrayWithOtherOwnersAndRevisions()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        var layout = Dict("Layout", ("Scope", Name("Row")), ("RowSpan", Num(9)));
        var table = Dict("Table", ("Scope", Name("Column")));
        var second = Dict("Table", ("Scope", Name("Row")), ("ColSpan", Num(4)));
        cell.Dictionary["A"] = new PdfArray([layout, new PdfNumber(1), table, new PdfNumber(0), second]);

        var attributes = tree.GetTableAttributes(cell);
        Assert.Equal(TableScope.Column, attributes.Scope);
        Assert.Null(attributes.RowSpan);
        Assert.Equal(4, attributes.ColSpan);
        Assert.Empty(attributes.Headers!);
    }

    [Fact]
    public void ReadsThroughReferences()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        var inner = document.Add(Dict("Table", ("Scope", Name("Row"))));
        cell.Dictionary["A"] = document.Add(new PdfArray([inner]));

        Assert.Equal(TableScope.Row, tree.GetTableAttributes(cell).Scope);
    }

    [Fact]
    public void MalformedAttributesReadAsNotSet()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();

        foreach (PdfObject junk in new PdfObject[] { new PdfNumber(3), new PdfName("Table"), new PdfArray([new PdfNumber(1), new PdfName("x")]), new PdfDictionary { ["Scope"] = Name("Row") } })
        {
            cell.Dictionary["A"] = junk;
            Assert.Null(tree.GetTableAttributes(cell).Scope);
            Assert.Null(tree.GetTableAttributes(cell).RowSpan);
        }

        cell.Dictionary["A"] = Dict("Table", ("Scope", Name("Rows")), ("RowSpan", Num(0)), ("ColSpan", PdfText.ToObject("x")), ("Headers", Num(5)));
        var attributes = tree.GetTableAttributes(cell);
        Assert.Null(attributes.Scope);
        Assert.Null(attributes.RowSpan);
        Assert.Null(attributes.ColSpan);
        Assert.Empty(attributes.Headers!);

        cell.Dictionary["A"] = Dict("Table", ("RowSpan", Num(-2)), ("Headers", new PdfArray([Num(1), PdfText.ToObject("ok"), new PdfArray([Num(2)])])));
        Assert.Null(tree.GetTableAttributes(cell).RowSpan);
        Assert.Equal(["ok"], tree.GetTableAttributes(cell).Headers);

        cell.Dictionary.Remove("A");
        Assert.Null(tree.GetTableAttributes(cell).Scope);
    }

    [Fact]
    public void SetCreatesTheDictionaryAndRoundTrips()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();

        tree.SetTableAttributes(cell, new TableAttributes(TableScope.Row, null, 2, 3));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        var back = read.GetTableAttributes(read.Elements.First(e => e.Type == "TD"));
        Assert.Equal(TableScope.Row, back.Scope);
        Assert.Equal((2, 3), (back.RowSpan, back.ColSpan));
        Assert.Equal("Table", again.Name(again.Dict(read.Elements.First(e => e.Type == "TD").Dictionary, "A"), "O"));
    }

    [Fact]
    public void SetKeepsOtherOwnersAndRevisionNumbers()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        var layout = Dict("Layout", ("Placement", Name("Block")));
        cell.Dictionary["A"] = new PdfArray([layout, new PdfNumber(2), Dict("Table", ("Scope", Name("Row")), ("Headers", Strings("h"))), new PdfNumber(3)]);

        tree.SetTableAttributes(cell, new TableAttributes(TableScope.Column, [], 4, null));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        var td = read.Elements.First(e => e.Type == "TD");
        var list = again.Array(td.Dictionary, "A")!;
        Assert.Equal(4, list.Items.Count);
        Assert.Equal("Block", again.Name((PdfDictionary)list.Items[0], "Placement"));
        Assert.Equal(2, ((PdfNumber)list.Items[1]).Integer);
        Assert.Equal(3, ((PdfNumber)list.Items[3]).Integer);
        var attributes = read.GetTableAttributes(td);
        Assert.Equal(TableScope.Column, attributes.Scope);
        Assert.Equal(4, attributes.RowSpan);
        Assert.Empty(attributes.Headers!);
    }

    [Fact]
    public void SetAddsATableDictionaryNextToAnotherOwners()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        cell.Dictionary["A"] = Dict("Layout", ("Placement", Name("Block")));

        tree.SetTableAttributes(cell, new TableAttributes(TableScope.Row));

        var list = Assert.IsType<PdfArray>(cell.Dictionary["A"]);
        Assert.Equal(2, list.Items.Count);
        Assert.Equal("Layout", document.Name((PdfDictionary)list.Items[0], "O"));
        Assert.Equal(TableScope.Row, tree.GetTableAttributes(cell).Scope);
    }

    [Fact]
    public void SetReplacesJunkAndClearsWhatIsEmpty()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        cell.Dictionary["A"] = new PdfNumber(7);

        tree.SetTableAttributes(cell, new TableAttributes(TableScope.Both, null, 1, 1));
        var table = Assert.IsType<PdfDictionary>(cell.Dictionary["A"]);
        Assert.False(table.ContainsKey("RowSpan"));
        Assert.False(table.ContainsKey("ColSpan"));

        tree.SetTableAttributes(cell, new TableAttributes());
        Assert.Null(cell.Dictionary["A"]);

        cell.Dictionary["A"] = new PdfArray([Dict("Layout"), Dict("Table", ("Scope", Name("Row"))), new PdfNumber(1)]);
        tree.SetTableAttributes(cell, new TableAttributes());
        var left = Assert.IsType<PdfArray>(cell.Dictionary["A"]);
        Assert.Single(left.Items);
        Assert.Equal("Layout", document.Name((PdfDictionary)left.Items[0], "O"));
    }

    [Fact]
    public void SettingWhatIsThereLeavesTheObjectsAlone()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        tree.SetTableAttributes(cell, new TableAttributes(TableScope.Row, null, 2, null));
        tree.Write(document);
        var saved = document.SaveIncremental();
        using var again = PdfDocument.Open(saved);
        var read = StructureTree.Read(again)!;
        var td = read.Elements.First(e => e.Type == "TD");
        var before = again.Dict(td.Dictionary, "A");

        read.SetTableAttributes(td, read.GetTableAttributes(td));
        read.Write(again);

        Assert.Same(before, again.Dict(td.Dictionary, "A"));
        Assert.Empty(again.ChangedObjects());
    }

    [Fact]
    public void HeadersGetIdsThatNoElementHas()
    {
        var (document, tree, table, rows) = Grid();
        using var _d = document;
        var head = rows[0].Children.ToArray();
        var cell = rows[1].Children.First();
        head[0].Id = "th1";

        tree.SetHeaders(cell, head);

        Assert.Equal("th1", head[0].Id);
        Assert.Equal("th2", head[1].Id);
        Assert.Equal(["th1", "th2"], tree.GetTableAttributes(cell).Headers);
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        var found = read.Elements.First(e => e.Type == "TR" && e != read.Elements.First(x => x.Type == "TR")).Children.First();
        Assert.Equal(["th1", "th2"], read.GetTableAttributes(found).Headers);
        var ids = PdfNameTree.Read(again, read.Dictionary["IDTree"]);
        Assert.Equal(["th1", "th2"], ids.Select(e => PdfNameTree.TextOf(e.Key)).Order());
        foreach (var entry in ids)
        {
            var target = read.Elements.First(e => e.Reference!.Number == ((PdfReference)entry.Value).Number);
            Assert.Equal(PdfNameTree.TextOf(entry.Key), target.Id);
        }
    }

    [Fact]
    public void AHeaderRowBecomesHeaderCells()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        tree.RoleMap["Cell"] = "TD";
        var custom = new StructElement("Cell");
        tree.Add(rows[0], custom);
        var first = rows[0].Children.First();
        first.Dictionary["A"] = new PdfArray([Dict("Layout", ("Placement", Name("Block"))), Dict("Table", ("Scope", Name("Row")), ("RowSpan", Num(2)))]);

        Assert.Equal(3, tree.MakeHeaderRow(rows[0]));

        Assert.All(rows[0].Children, c => Assert.Equal("TH", c.Type));
        Assert.All(rows[0].Children, c => Assert.Equal(TableScope.Column, tree.GetTableAttributes(c).Scope));
        Assert.Equal(2, tree.GetTableAttributes(first).RowSpan);
        Assert.Equal("Layout", document.Name((PdfDictionary)((PdfArray)first.Dictionary["A"]!).Items[0], "O"));
        Assert.All(rows[1].Children, c => Assert.Equal("TD", c.Type));
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var read = StructureTree.Read(again)!;
        var header = read.Elements.First(e => e.Type == "TR");
        Assert.All(header.Children, c => Assert.Equal(TableScope.Column, read.GetTableAttributes(c).Scope));
    }

    [Fact]
    public void ARowOfCustomHeaderCellsKeepsTheirType()
    {
        var (document, tree, table, _) = Grid();
        using var _d = document;
        tree.RoleMap["Head"] = "TH";
        tree.RoleMap["Line"] = "TR";
        var row = new StructElement("Line");
        tree.Add(table, row);
        var cell = new StructElement("Head");
        tree.Add(row, cell);
        tree.Add(row, new StructElement("P"));

        Assert.Equal(1, tree.MakeHeaderRow(row));
        Assert.Equal("Head", cell.Type);
        Assert.Equal(TableScope.Column, tree.GetTableAttributes(cell).Scope);
    }

    [Fact]
    public void OnlyARowIsTurnedIntoHeaders()
    {
        var (document, tree, table, rows) = Grid();
        using var _d = document;

        Assert.Equal(0, tree.MakeHeaderRow(table));
        Assert.Equal(0, tree.MakeHeaderRow(rows[0].Children.First()));
        Assert.All(rows[0].Children, c => Assert.Equal("TD", c.Type));
    }

    [Fact]
    public void ClearingAValueAlsoClearsItInLaterDictionaries()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        var first = Dict("Table", ("Scope", Name("Column")));
        var second = Dict("Table", ("RowSpan", Num(3)), ("Scope", Name("Row")), ("Headers", Strings("a")));
        cell.Dictionary["A"] = new PdfArray([first, new PdfNumber(0), second, new PdfNumber(1)]);

        tree.SetTableAttributes(cell, tree.GetTableAttributes(cell) with { RowSpan = 1, Headers = [] });
        Assert.Null(tree.GetTableAttributes(cell).RowSpan);
        Assert.Empty(tree.GetTableAttributes(cell).Headers!);
        Assert.Equal(TableScope.Column, tree.GetTableAttributes(cell).Scope);

        tree.SetTableAttributes(cell, tree.GetTableAttributes(cell) with { Scope = null });
        Assert.Null(tree.GetTableAttributes(cell).Scope);
        Assert.Null(cell.Dictionary["A"]);
    }

    [Fact]
    public void LaterDictionariesKeepWhatIsNotATableValue()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[0].Children.First();
        var second = Dict("Table", ("RowSpan", Num(3)), ("Summary", PdfText.ToObject("s")));
        var shared = document.Add(second);
        cell.Dictionary["A"] = new PdfArray([Dict("Table", ("Scope", Name("Row"))), shared]);

        tree.SetTableAttributes(cell, new TableAttributes(TableScope.Row));

        Assert.Equal(3, ((PdfNumber)second["RowSpan"]!).Integer);
        Assert.Null(tree.GetTableAttributes(cell).RowSpan);
        Assert.Equal("s", PdfText.Read(document, (PdfDictionary)document.Resolve(((PdfArray)cell.Dictionary["A"]!).Items[1])!, "Summary"));
    }

    [Fact]
    public void HeadersKeepTheirStoredBytes()
    {
        var (document, tree, _, rows) = Grid();
        using var _d = document;
        var cell = rows[1].Children.First();
        byte[] raw = [0xFE, 0xFF, 0x00, 0x74, 0x00, 0x68, 0x00, 0x31];
        cell.Dictionary["A"] = Dict("Table", ("Headers", new PdfArray([new PdfString(raw, true)])));

        tree.SetTableAttributes(cell, tree.GetTableAttributes(cell) with { Scope = TableScope.Row });
        tree.SetTableAttributes(cell, tree.GetTableAttributes(cell) with { Headers = ["th1", "new"] });

        var headers = ((PdfArray)((PdfDictionary)cell.Dictionary["A"]!)["Headers"]!).Items;
        Assert.Equal(raw, ((PdfString)headers[0]).Bytes);
        Assert.Equal("new", PdfText.Decode(((PdfString)headers[1]).Bytes));
    }
}
