using System.Text;

namespace LazyPDF.Core;

// Moving text with a matrix round it. A cm is not allowed inside a text object, so the object is
// left before the text and entered again after it, with the text matrices put back as they were.
// A run of glyphs may start or end in the middle of a string; the string is then cut in two there.
internal sealed partial class ObjectEditor
{
    private static bool IsPainting(ContentOperation op) =>
        op.Operator is "Tj" or "TJ" or "'" or "\"" or "Do" or "BI" or "sh" or "S" or "s" or "f" or "F" or "f*" or "B" or "B*" or "b" or "b*";

    private static bool IsPositioning(ContentOperation op) =>
        op.Operator is "Td" or "TD" or "Tm" or "T*" or "'" or "\"" or "BT" or "ET";

    private void TransformText(TextObject block, PdfMatrix t)
    {
        foreach (var group in block.Glyphs.SelectMany(g => g.Twins.Prepend(g)).GroupBy(g => (g.Unit, g.Visit)))
        {
            var place = new Place(group.Key.Unit, group.Key.Visit);
            var glyphs = group.OrderBy(g => g.Op).ThenBy(g => g.Element).ThenBy(g => g.Offset).ToList();
            var own = glyphs.ToHashSet();
            var ownOps = glyphs.Select(g => g.Op).ToHashSet();
            var runs = new List<List<EditGlyph>>();
            foreach (var g in glyphs)
            {
                if (runs.Count > 0 && Joins(place.Unit, runs[^1][^1], g, own, ownOps)) runs[^1].Add(g);
                else runs.Add([g]);
            }
            foreach (var run in runs) TransformRun(place, run, t);
        }
    }

    // Two glyphs go in one wrap when nothing foreign is painted between them, the q levels balance between them,
    // and no cm changes the matrix in between.
    private bool Joins(ContentUnit unit, EditGlyph a, EditGlyph b, HashSet<EditGlyph> own, HashSet<int> ownOps)
    {
        if (a.Op == b.Op) return !ForeignBetween(unit, a, b, own);
        var ops = unit.Operations;
        for (int i = a.Op + 1; i < b.Op; i++)
        {
            if (ops[i].Operator == "cm" || (IsPainting(ops[i]) && !ownOps.Contains(i))) return false;
        }
        return Near(a.Ctm, b.Ctm) && TextEditor.Balanced(unit, a.Op, b.Op) && !ForeignBetween(unit, a, b, own);
    }

    // A glyph of another object shown between the two, in their strings or the ones between.
    private bool ForeignBetween(ContentUnit unit, EditGlyph a, EditGlyph b, HashSet<EditGlyph> own)
    {
        for (int op = a.Op; op <= b.Op; op++)
        {
            foreach (var g in model.GlyphsAt(unit, op))
            {
                if (own.Contains(g)) continue;
                bool afterA = op > a.Op || (g.Element, g.Offset).CompareTo((a.Element, a.Offset)) > 0;
                bool beforeB = op < b.Op || (g.Element, g.Offset).CompareTo((b.Element, b.Offset)) < 0;
                if (afterA && beforeB) return true;
            }
        }
        return false;
    }

    private void TransformRun(Place place, List<EditGlyph> run, PdfMatrix t)
    {
        var unit = place.Unit;
        var ops = unit.Operations;
        var (first, last) = (run[0], run[^1]);
        var around = Around(first.Ctm, t);
        var back = around.Invert() ?? throw new EditConflictException(EditingText.TooBig);
        bool startsMid = model.GlyphsAt(unit, first.Op)[0] != first;
        bool endsMid = model.GlyphsAt(unit, last.Op)[^1] != last;
        // Mid-string the text matrix can only be set whole, so nothing may position text again until the run ends.
        if (startsMid)
        {
            for (int i = first.Op + 1; i <= last.Op; i++)
            {
                if (IsPositioning(ops[i])) throw new EditConflictException(EditingText.NotAlone);
            }
        }

        int bt = -1;
        for (int i = first.Op - 1; !startsMid && i >= 0; i--)
        {
            if (ops[i].Operator == "BT")
            {
                bt = i;
                break;
            }
            if (ops[i].Operator == "ET" || IsPainting(ops[i])) break;
        }
        int et = -1;
        for (int i = last.Op + 1; !endsMid && i < ops.Count; i++)
        {
            if (ops[i].Operator == "ET")
            {
                et = i;
                break;
            }
            if (IsPainting(ops[i]) || ops[i].Operator == "BT") break;
        }
        int startIndex = bt >= 0 ? bt : first.Op, endIndex = et >= 0 ? et : last.Op;
        if (!TextEditor.Balanced(unit, startIndex, endIndex)) throw new EditConflictException(EditingText.Unbalanced);

        string forward = Matrix(around), reverse = Matrix(back);
        if (bt >= 0) Insert(place, ops[bt].Start, forward);
        else if (startsMid) InsertInString(place, first, 0, "ET\n" + forward + "BT\n" + Matrix1(first.TextMatrix, "Tm"));
        else Insert(place, ops[first.Op].Start, "ET\n" + forward + "BT\n" + Matrix1(StartMatrix(first), "Tm"));
        if (et >= 0) Insert(place, ops[et].End, "\n" + reverse);
        else if (endsMid) InsertInString(place, last, last.Length, "\nET\n" + reverse + "BT\n" + EndState(last, false));
        else Insert(place, ops[last.Op].End, "\nET\n" + reverse + "BT\n" + EndState(last, true));
    }

    // Operators written inside a string, which splits the operation there.
    private void InsertInString(Place place, EditGlyph at, int after, string text)
    {
        var patch = batch.Patch(place, at.Op) ?? throw new EditConflictException(EditingText.SharedForm);
        patch.Insert(at.Element, at.Offset + after, [new ShowOps(Bytes(text))]);
    }

    private static bool Near(PdfMatrix a, PdfMatrix b) =>
        Math.Abs(a.A - b.A) + Math.Abs(a.B - b.B) + Math.Abs(a.C - b.C) + Math.Abs(a.D - b.D) + Math.Abs(a.E - b.E) + Math.Abs(a.F - b.F) < 1e-4;

    private static string Matrix1(PdfMatrix m, string op) =>
        Encoding.Latin1.GetString(new ContentWriter().Op(op, m.A, m.B, m.C, m.D, m.E, m.F).ToArray());

    // The line matrix a show operation starts from, which is also the text matrix there: a positioning operator sets both.
    private static PdfMatrix StartMatrix(EditGlyph first)
    {
        var op = first.Unit.Operations[first.Op];
        if (op.Operator is "'" or "\"") return PdfMatrix.Translate(0, first.Leading).Multiply(first.TextLineMatrix);
        double shift = LeadingShift(op, first);
        var before = PdfMatrix.Translate(-shift, 0).Multiply(first.TextMatrix);
        if (!Near(before, first.TextLineMatrix)) throw new EditConflictException(EditingText.NotAlone);
        return first.TextLineMatrix;
    }

    // Text space distance the numbers of a TJ array in front of the first string move the text by.
    private static double LeadingShift(ContentOperation op, EditGlyph first)
    {
        double shift = 0;
        if (op.Operator == "TJ" && op.Operands[^1] is PdfArray array)
        {
            for (int i = 0; i < first.Element && i < array.Items.Count; i++)
            {
                if (array.Items[i] is PdfNumber n) shift += -n.Value / 1000 * first.FontSize * first.Scale;
            }
        }
        return shift;
    }

    // Operators that leave the line matrix and the text matrix as the content had them after the last glyph.
    // Numbers after the glyph in its TJ array count when the operation ends there.
    private static string EndState(EditGlyph last, bool trailing)
    {
        var op = last.Unit.Operations[last.Op];
        double shift = last.Advance;
        if (trailing && op.Operator == "TJ" && op.Operands[^1] is PdfArray array)
        {
            for (int i = last.Element + 1; i < array.Items.Count; i++)
            {
                if (array.Items[i] is PdfNumber n) shift += -n.Value / 1000 * last.FontSize * last.Scale;
            }
        }
        var line = last.TextLineMatrix;
        var after = PdfMatrix.Translate(shift, 0).Multiply(last.TextMatrix);
        var text = Matrix1(line, "Tm");
        if (Near(after, line)) return text;
        // The text matrix sits along the line from the line matrix: a number in a TJ array moves it there.
        double dx = after.E - line.E, dy = after.F - line.F;
        double square = line.A * line.A + line.B * line.B;
        double along = square < 1e-12 ? 0 : (dx * line.A + dy * line.B) / square;
        if (!Near(PdfMatrix.Translate(along, 0).Multiply(line), after)) throw new EditConflictException(EditingText.NotAlone);
        double amount = -along * 1000 / (last.FontSize * last.Scale);
        return text + Encoding.Latin1.GetString(new ContentWriter().Op("TJ", [new PdfArray([new PdfNumber(amount)])]).ToArray());
    }
}
