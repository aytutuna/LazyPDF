using System.Windows;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Comment;

// What the panel asks of the engine: marks made from page points, found again under the pointer, changed and removed.
public sealed class MarkerTests
{
    private static readonly MarkStyle Red = MarkStyle.Default with { Color = [0.9, 0.1, 0.1] };

    private static readonly Point[] Drag = [new(60, 80), new(260, 140)];

    [Theory]
    [InlineData(MarkTool.Rectangle, AnnotationType.Square)]
    [InlineData(MarkTool.Oval, AnnotationType.Circle)]
    [InlineData(MarkTool.Line, AnnotationType.Line)]
    [InlineData(MarkTool.Arrow, AnnotationType.Line)]
    [InlineData(MarkTool.TextBox, AnnotationType.FreeText)]
    [InlineData(MarkTool.Note, AnnotationType.Text)]
    public void EachToolMakesItsKindOfMark(MarkTool tool, AnnotationType type)
    {
        using var f = new CommentFixture();

        var made = f.Marker.Add(tool, 0, Drag, Red, "Look here");

        Assert.Equal(type, made.Type);
        Assert.True(made.HasAppearance);
        Assert.Equal("Ana", made.Title);
        Assert.Single(f.Marks());
    }

    [Theory]
    [InlineData(MarkTool.Polygon, AnnotationType.Polygon)]
    [InlineData(MarkTool.Cloud, AnnotationType.Polygon)]
    [InlineData(MarkTool.Pencil, AnnotationType.Ink)]
    public void ToolsThatTakeManyPointsUseAllOfThem(MarkTool tool, AnnotationType type)
    {
        using var f = new CommentFixture();
        Point[] points = [new(50, 50), new(150, 60), new(140, 160), new(40, 150)];

        var made = f.Marker.Add(tool, 0, points, Red);

        Assert.Equal(type, made.Type);
        Assert.Equal(tool == MarkTool.Pencil ? 0 : 8, made.Vertices.Count);
        if (tool == MarkTool.Cloud) Assert.True(made.Cloud > 0);
        if (tool == MarkTool.Pencil) Assert.Equal(8, made.InkList[0].Count);
    }

    [Fact]
    public void ADraggedBoxComesBackWhereItWasDrawn()
    {
        using var f = new CommentFixture();

        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);

        var box = f.Marker.BoxOf(made);
        Assert.Equal(60, box.Left, 0.5);
        Assert.Equal(80, box.Top, 0.5);
        Assert.Equal(200, box.Width, 0.5);
        Assert.Equal(60, box.Height, 0.5);
        Assert.Equal(f.Geometry.Height - 140, made.Rect.Bottom, 0.5);
    }

    [Fact]
    public void ABoxDrawnOnATurnedPageComesBackWhereItWasDrawn()
    {
        using var f = new CommentFixture();
        f.Document.Pages[0].Dictionary["Rotate"] = new PdfNumber(90);

        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);

        var box = f.Marker.BoxOf(made);
        Assert.Equal(60, box.Left, 0.5);
        Assert.Equal(80, box.Top, 0.5);
        Assert.Equal(200, box.Width, 0.5);
    }

    [Fact]
    public void APictureStampIsAnImageStampOfTheStampWidth()
    {
        using var f = new CommentFixture();
        var picture = new PdfRgbaImage(2, 1, [255, 0, 0, 255, 0, 255, 0, 255]);

        var made = f.Marker.AddPictureStamp(0, new Point(200, 200), picture);

        var read = Assert.Single(f.Marks());
        Assert.Equal(AnnotationType.Stamp, read.Type);
        Assert.Equal(Marker.StampWidth, read.Rect.Width, 0.5);
        Assert.Equal(Marker.StampWidth / 2, read.Rect.Height, 0.5);
        Assert.True(read.HasAppearance);
        Assert.Equal("Ana", made.Title);
    }

    [Fact]
    public void APictureStampOnATurnedPageKeepsItsAppearance()
    {
        using var f = new CommentFixture();
        f.Document.Pages[0].Dictionary["Rotate"] = new PdfNumber(90);
        var picture = new PdfRgbaImage(2, 1, [255, 0, 0, 255, 0, 255, 0, 255]);

        f.Marker.AddPictureStamp(0, new Point(200, 200), picture);

        var read = Assert.Single(f.Marks());
        Assert.Equal(AnnotationType.Stamp, read.Type);
        Assert.True(read.HasAppearance);
        Assert.Equal(Marker.StampWidth / 2, read.Rect.Width, 0.5);
        Assert.Equal(Marker.StampWidth, read.Rect.Height, 0.5);
    }

    [Fact]
    public void ACalloutSitsAtTheEndOfTheDragAndPointsBack()
    {
        using var f = new CommentFixture();
        Point[] drag = [new(100, 100), new(300, 200)];

        var made = f.Marker.Add(MarkTool.Callout, 0, drag, Red, "See the chart");

        Assert.Equal(AnnotationType.FreeText, made.Type);
        Assert.Equal(4, made.Callout.Count);
        var (x, y) = f.Geometry.ToUser(100, 100);
        Assert.Equal(x, made.Callout[0], 0.5);
        Assert.Equal(y, made.Callout[1], 0.5);
        var box = Marker.BoxOf(MarkTool.Callout, drag);
        Assert.Equal(300, box.X + box.Width / 2, 0.01);
        Assert.Equal(200, box.Y + box.Height / 2, 0.01);
    }

    [Theory]
    [InlineData("font-family: 'Calibri', sans-serif", "Calibri")]
    [InlineData("font-family: 'helvetica'", "Helvetica")]
    [InlineData("font-family: monospace", "Courier New")]
    public void TheFirstFontOfAStyleListIsTheFamily(string style, string family)
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.TextBox, 0, Drag, Red, "Look here");

        var read = Marker.TextOf(made with { DefaultStyle = style });

        Assert.Equal(family, read.Family);
    }

    [Fact]
    public void TextTheFontsCannotDrawIsRefusedAndLeavesNoMark()
    {
        using var f = new CommentFixture();

        var error = Assert.Throws<InvalidOperationException>(() => f.Marker.Add(MarkTool.TextBox, 0, Drag, Red, "Çalışma ğ"));

        Assert.Equal(AnnotationText.NoFont, error.Message);
        Assert.Empty(f.Marks());
    }

    [Fact]
    public void AToolThatDoesNotDrawByItselfIsRefused()
    {
        using var f = new CommentFixture();

        Assert.Throws<ArgumentException>(() => f.Marker.Add(MarkTool.Eraser, 0, Drag, Red));
    }

    [Fact]
    public void ASelectedRunBecomesOneMarkupWithItsQuadsInAcrobatOrder()
    {
        using var f = new CommentFixture();
        var quad = new TextQuad(100, 700, 180, 700, 180, 712, 100, 712);
        var run = new SelectedRun(0, default, "Hello", [quad]);

        int count = f.Marker.Markup(AnnotationType.Highlight, [run], MarkStyle.Default);

        Assert.Equal(1, count);
        var made = Assert.Single(f.Marks());
        Assert.Equal(AnnotationType.Highlight, made.Type);
        Assert.Equal([100.0, 712, 180, 712, 100, 700, 180, 700], made.QuadPoints);
    }

    [Fact]
    public void ARunWithNoQuadsMarksNothing()
    {
        using var f = new CommentFixture();

        int count = f.Marker.Markup(AnnotationType.Underline, [new SelectedRun(0, default, "", [])], MarkStyle.Default);

        Assert.Equal(0, count);
        Assert.Empty(f.Marks());
    }

    [Fact]
    public void AStampAndAnAttachmentLandWhereTheyWereClicked()
    {
        using var f = new CommentFixture();

        var stamp = f.Marker.AddStamp(0, new Point(200, 300), "Approved", MarkStyle.Default);
        var file = f.Marker.AddAttachment(0, new Point(400, 100), "data.csv", [1, 2, 3]);

        Assert.Equal(AnnotationType.Stamp, stamp.Type);
        Assert.Equal(200, f.Marker.BoxOf(stamp).X + Marker.StampWidth / 2, 0.5);
        Assert.Equal(AnnotationType.FileAttachment, file.Type);
        Assert.Equal(400, f.Marker.BoxOf(file).X, 0.5);
    }

    [Fact]
    public void ADatedStampIsWiderAndKeepsTheColourOfItsStandardName()
    {
        using var f = new CommentFixture();

        var stamp = f.Marker.AddStamp(0, new Point(200, 300), "APPROVED 2026-11-11", MarkStyle.Default with { Color = Marker.StampColor("Approved") }, dated: true);

        var read = f.Marks().Single();
        Assert.Equal("APPROVED 2026-11-11", read.IconName);
        Assert.Equal(Marker.DatedStampWidth, f.Marker.BoxOf(stamp).Width, 0.5);
        Assert.Equal([0, 0.5, 0.15], Marker.StampColor("Approved"));
        Assert.Equal([0.75, 0, 0], Marker.StampColor("Draft"));
    }

    [Fact]
    public void ThePointerFindsTheTopmostMarkUnderIt()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Rectangle, 0, [new Point(50, 50), new Point(250, 250)], Red);
        var top = f.Marker.Add(MarkTool.Oval, 0, [new Point(100, 100), new Point(200, 200)], Red);

        Assert.Equal(top.Reference!.Number, f.Marker.At(0, new Point(100, 150), 4)!.Reference!.Number);
        Assert.Equal(AnnotationType.Square, f.Marker.At(0, new Point(50, 150), 4)!.Type);
        Assert.Null(f.Marker.At(0, new Point(400, 400), 4));
    }

    [Fact]
    public void ALineIsFoundNearItsStrokeAndNotInTheEmptyCornerOfItsBox()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Line, 0, [new Point(100, 100), new Point(300, 300)], Red);

        Assert.NotNull(f.Marker.At(0, new Point(200, 201), 4));
        Assert.Null(f.Marker.At(0, new Point(300, 100), 4));
    }

    [Fact]
    public void AnInkStrokeIsFoundNearItsPoints()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Pencil, 0, [new Point(100, 100), new Point(200, 100), new Point(200, 200)], Red);

        Assert.NotNull(f.Marker.At(0, new Point(150, 101), 4));
        Assert.Null(f.Marker.At(0, new Point(100, 200), 4));
    }

    [Fact]
    public void RepliesAreNotPickedUpOnThePage()
    {
        using var f = new CommentFixture();
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(100, 100)], Red, "Question");
        var reply = PdfComments.Reply(f.Document, note, "Answer", "Can", DateTimeOffset.Now);

        Assert.False(Marker.Selectable(reply));
        Assert.True(Marker.Selectable(note));
    }

    [Fact]
    public void MovingShiftsTheMarkByTheDragInPageSpace()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);

        var moved = f.Marker.Move(made, new Vector(10, 20));

        var box = f.Marker.BoxOf(moved);
        Assert.Equal(70, box.Left, 0.5);
        Assert.Equal(100, box.Top, 0.5);
        Assert.Equal(200, box.Width, 0.5);
    }

    [Fact]
    public void ResizingFitsTheMarkIntoTheNewBox()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);

        var resized = f.Marker.Resize(made, new Rect(50, 70, 300, 120));

        var box = f.Marker.BoxOf(resized);
        Assert.Equal(50, box.Left, 0.5);
        Assert.Equal(300, box.Width, 0.5);
        Assert.Equal(120, box.Height, 0.5);
    }

    [Fact]
    public void ColourWidthAndOpacityChangeTheMarkAndKeepItsLook()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);

        var blue = f.Marker.Recolor(made, [0, 0, 1]);
        var wide = f.Marker.SetWidth(blue, 6);
        var faint = f.Marker.SetOpacity(wide, 0.5);

        Assert.Equal([0.0, 0, 1], faint.Color);
        Assert.Equal(6, faint.Border.Width);
        Assert.Equal(0.5, faint.Opacity);
        Assert.True(faint.HasAppearance);
    }

    [Fact]
    public void AFilledDashedRectangleKeepsItsFillAndDashAfterReading()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red with { Fill = [1, 0.92, 0.2], Dash = LineStyle.Dashed, Width = 2 });

        var read = f.Marks().Single(m => m.Reference?.Number == made.Reference?.Number);

        Assert.Equal([1, 0.92, 0.2], read.InteriorColor!);
        Assert.Equal(BorderStyle.Dashed, read.Border.Style);
        Assert.Equal([6.0, 4], read.Border.Dash);
        Assert.Equal(LineStyle.Dashed, Marker.LineOf(read));
    }

    [Fact]
    public void ADottedLineIsReadBackAsDotted()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Line, 0, Drag, Red with { Dash = LineStyle.Dotted });

        Assert.Equal(LineStyle.Dotted, Marker.LineOf(f.Marks().Single(m => m.Reference?.Number == made.Reference?.Number)));
    }

    [Fact]
    public void WideningADashedOrDottedMarkKeepsItsLineStyle()
    {
        using var f = new CommentFixture();
        var dashed = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red with { Dash = LineStyle.Dashed });
        var dotted = f.Marker.Add(MarkTool.Oval, 0, Drag, Red with { Width = 12, Dash = LineStyle.Dotted });

        Assert.Equal(LineStyle.Dashed, Marker.LineOf(f.Marker.SetWidth(dashed, 6)));
        Assert.Equal(LineStyle.Dotted, Marker.LineOf(f.Marker.SetWidth(dotted, 2)));
        Assert.Equal(LineStyle.Solid, Marker.LineOf(f.Marker.SetWidth(f.Marker.Add(MarkTool.Line, 0, Drag, Red), 6)));
    }

    [Fact]
    public void ACalloutTakesAFillAndALineStyleLikeAShape()
    {
        using var f = new CommentFixture();
        var callout = f.Marker.Add(MarkTool.Callout, 0, Drag, Red, "See the chart");
        var box = f.Marker.Add(MarkTool.TextBox, 0, Drag, Red, "Plain");

        Assert.True(Marker.TakesFill(callout));
        Assert.True(Marker.TakesLine(callout));
        Assert.False(Marker.TakesFill(box));
    }

    [Fact]
    public void ChangingTheHeadAgainDoesNotGrowTheBoxAgain()
    {
        using var f = new CommentFixture();
        var line = f.Marker.Add(MarkTool.Line, 0, Drag, Red);

        var first = f.Marker.SetEnding(line, LineEnding.Diamond);
        var second = f.Marker.SetEnding(first, LineEnding.OpenArrow);

        Assert.Equal(first.Rect.Width, second.Rect.Width);
        Assert.Equal(first.Rect.Height, second.Rect.Height);

        var wide = f.Marker.SetWidth(second, 6);
        var bare = f.Marker.SetEnding(wide, LineEnding.None);
        Assert.True(bare.Rect.Left < Math.Min(bare.Line[0], bare.Line[2]));
        bare = f.Marker.SetEnding(f.Marker.SetWidth(bare, line.Border.Width), LineEnding.None);
        var again = f.Marker.SetEnding(bare, LineEnding.Diamond);

        Assert.Equal(line.Rect.Width, bare.Rect.Width, 6);
        Assert.Equal(first.Rect.Width, again.Rect.Width, 6);
    }

    [Fact]
    public void TheDashKeepsTheWidthOfAMarkThatOnlyHadABorder()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Oval, 0, Drag, Red);
        made.Dictionary.Remove("BS");
        made.Dictionary["Border"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(4)]);

        var dotted = f.Marker.SetDash(f.Marker.Find(0, made.Reference!.Number)!, LineStyle.Dotted);

        Assert.Equal(4, dotted.Border.Width);
    }

    [Fact]
    public void TheFillAndTheDashCanBeChangedAndTakenAway()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Oval, 0, Drag, Red);

        var filled = f.Marker.SetFill(made, [0, 0, 1]);
        var dotted = f.Marker.SetDash(filled, LineStyle.Dotted);
        Assert.Equal([0.0, 0, 1], dotted.InteriorColor!);
        Assert.Equal(LineStyle.Dotted, Marker.LineOf(dotted));

        var plain = f.Marker.SetDash(f.Marker.SetFill(dotted, null), LineStyle.Solid);
        Assert.False(plain.Dictionary.ContainsKey("IC"));
        Assert.Equal(BorderStyle.Solid, plain.Border.Style);
        Assert.Equal([0.9, 0.1, 0.1], plain.Color!);
    }

    [Fact]
    public void RecolouringAFilledShapeLeavesItsFill()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red with { Fill = [1, 0, 0] });

        var blue = f.Marker.Recolor(made, [0, 0, 1]);

        Assert.Equal([0.0, 0, 1], blue.Color!);
        Assert.Equal([1.0, 0, 0], blue.InteriorColor!);
    }

    [Fact]
    public void EditedTextIsKeptAndANoteDoesNotNeedAFont()
    {
        using var f = new CommentFixture();
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(100, 100)], Red, "First");

        var edited = f.Marker.SetText(note, "Second, with ğ");

        Assert.Equal("Second, with ğ", edited.Contents);
    }

    [Fact]
    public void DeletingAMarkRemovesItsRepliesToo()
    {
        using var f = new CommentFixture();
        var note = f.Marker.Add(MarkTool.Note, 0, [new Point(100, 100)], Red, "Question");
        PdfComments.Reply(f.Document, note, "Answer", "Can", DateTimeOffset.Now);
        Assert.Equal(2, f.Marks().Count);

        Assert.True(f.Marker.Delete(f.Marks()[0]));

        Assert.Empty(f.Marks());
    }

    [Fact]
    public void FindingAMarkAgainAfterACommitUsesItsObjectNumber()
    {
        using var f = new CommentFixture();
        var made = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);
        int number = made.Reference!.Number;

        f.Tab.Commit("Rectangle");

        Assert.Equal(AnnotationType.Square, f.Marker.Find(0, number)!.Type);
        Assert.Null(f.Marker.Find(0, number + 100));
        Assert.Null(f.Marker.Find(5, number));
    }

    [Fact]
    public void AMarkIsOneUndoStepAndSurvivesAReread()
    {
        using var f = new CommentFixture();
        f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);

        Assert.True(f.Tab.Commit("Rectangle"));
        var reread = PdfDocument.Open(f.Tab.Session.Current.ToArray());
        Assert.Single(PdfAnnotations.Read(reread, reread.Pages[0]));

        Assert.True(f.Tab.Undo());
        Assert.Empty(f.Marks());
    }

    [Fact]
    public void AnArrowTakesTheChosenHeadAndStaysAnArrowToOtherReaders()
    {
        using var f = new CommentFixture();

        var made = f.Marker.Add(MarkTool.Arrow, 0, Drag, Red with { Head = LineEnding.ClosedArrow });

        var read = f.Marks().Single();
        Assert.Equal(LineEnding.ClosedArrow, read.EndEnding);
        Assert.Equal(LineEnding.None, read.StartEnding);
        Assert.Equal("LineArrow", read.Intent);
        Assert.True(made.HasAppearance);
    }

    [Fact]
    public void ANoteTakesTheChosenIcon()
    {
        using var f = new CommentFixture();

        f.Marker.Add(MarkTool.Note, 0, Drag, Red with { Icon = "Key" });

        Assert.Equal("Key", f.Marks().Single().IconName);
    }

    [Fact]
    public void TheHeadAndTheIconOfAMarkAreChanged()
    {
        using var f = new CommentFixture();
        var line = f.Marker.Add(MarkTool.Line, 0, Drag, Red);
        var note = f.Marker.Add(MarkTool.Note, 0, [new(200, 300)], Red);
        double width = line.Rect.Width;

        var headed = f.Marker.SetEnding(line, LineEnding.Diamond);
        var iconed = f.Marker.SetIcon(note, "Help");

        Assert.Equal(LineEnding.Diamond, headed.EndEnding);
        Assert.Equal(LineEnding.None, headed.StartEnding);
        Assert.True(headed.Rect.Width > width);
        Assert.True(headed.HasAppearance);
        Assert.Equal("Help", iconed.IconName);
    }

    [Fact]
    public void MovingOneEndOfALineLeavesTheOtherAndKeepsBothInTheBox()
    {
        using var f = new CommentFixture();
        var line = f.Marker.Add(MarkTool.Line, 0, [new Point(100, 100), new Point(300, 300)], Red);

        var moved = f.Marker.MovePoint(line, 1, new Point(400, 200));

        var ends = f.Marker.PointsOf(moved)!;
        Assert.Equal(100, ends[0].X, 0.5);
        Assert.Equal(100, ends[0].Y, 0.5);
        Assert.Equal(400, ends[1].X, 0.5);
        Assert.Equal(200, ends[1].Y, 0.5);
        var box = f.Marker.BoxOf(moved);
        Assert.True(box.Contains(ends[0]) && box.Contains(ends[1]));
        Assert.True(moved.HasAppearance);
    }

    [Fact]
    public void MovingACornerOfAPolygonChangesOnlyThatCorner()
    {
        using var f = new CommentFixture();
        var shape = f.Marker.Add(MarkTool.Polygon, 0, [new Point(100, 100), new Point(300, 100), new Point(300, 300), new Point(100, 300)], Red);

        var moved = f.Marker.MovePoint(shape, 2, new Point(350, 350));

        var corners = f.Marker.PointsOf(moved)!;
        Assert.Equal(4, corners.Length);
        Assert.Equal(350, corners[2].X, 0.5);
        Assert.Equal(350, corners[2].Y, 0.5);
        Assert.Equal(300, corners[1].X, 0.5);
        Assert.Equal(100, corners[3].X, 0.5);
    }

    [Fact]
    public void ACloudHasNoPointsToMove()
    {
        using var f = new CommentFixture();
        var cloud = f.Marker.Add(MarkTool.Cloud, 0, [new Point(100, 100), new Point(300, 100), new Point(300, 300), new Point(100, 300)], Red);

        Assert.Null(f.Marker.PointsOf(cloud));
        Assert.Throws<ArgumentException>(() => f.Marker.MovePoint(cloud, 0, new Point(10, 10)));
    }

    [Fact]
    public void AMeasurementAndABoxHaveNoPointsToMove()
    {
        using var f = new CommentFixture();
        var line = f.Marker.Add(MarkTool.Line, 0, Drag, Red);
        line.Dictionary["Measure"] = new PdfDictionary();
        var box = f.Marker.Add(MarkTool.Rectangle, 0, Drag, Red);

        Assert.Null(f.Marker.PointsOf(line));
        Assert.Null(f.Marker.PointsOf(box));
        Assert.Throws<ArgumentException>(() => f.Marker.MovePoint(line, 0, new Point(10, 10)));
    }
}
