using System.Text;

namespace LazyPDF.Core;

/// <summary>A picture taken out of the file: its bytes and the extension of the file they make.</summary>
public sealed record ExtractedImage(byte[] Data, string Extension);

internal sealed partial class ObjectEditor
{
    public IImageCodec? Codec { get; init; }

    /// <summary>Paints another picture where the object is, fitted inside its place with the proportions of the new one.</summary>
    public void ReplaceImage(ImageObject image, byte[] file, bool fit)
    {
        PdfImage? added = file.Length > 2 && file[0] == 0xFF && file[1] == 0xD8 ? PdfImageWriter.AddJpeg(Document, file) : null;
        if (added is null && Codec?.DecodeFile(file) is { Count: > 0 } frames)
        {
            var frame = frames[0];
            added = PdfImageWriter.AddRgba(Document, frame.Width, frame.Height, frame.Rgba);
        }
        if (added is null) throw new EditConflictException(EditingText.NoImage);
        var place = PlaceOf(image);
        string name = batch.AddResource(place, "XObject", added.Reference) ?? throw new EditConflictException(EditingText.SharedForm);
        var w = new ContentWriter();
        double across = Math.Sqrt(image.Placement.A * image.Placement.A + image.Placement.B * image.Placement.B);
        double down = Math.Sqrt(image.Placement.C * image.Placement.C + image.Placement.D * image.Placement.D);
        if (fit && across > 0 && down > 0)
        {
            double shape = (double)added.Width / added.Height, room = across / down;
            var inside = shape > room ? new PdfMatrix(1, 0, 0, room / shape, 0, (1 - room / shape) / 2) : new PdfMatrix(shape / room, 0, 0, 1, (1 - shape / room) / 2, 0);
            w.Save().Concat(inside).Paint(name).Restore();
        }
        else w.Paint(name);
        var op = image.Unit.Operations[image.Op];
        string drawn = Encoding.Latin1.GetString(w.ToArray()).TrimEnd('\n');
        Replace(place, op.Start, op.End, drawn);
    }

    /// <summary>The bytes of the picture: a JPEG or JPEG 2000 file as it is stored, anything else as a PNG.</summary>
    public ExtractedImage Extract(ImageObject image)
    {
        if (image.Info.Inline is { } inline)
        {
            return Encode(image.Info.Dictionary, inline.Data, null);
        }
        var stream = image.Info.Stream ?? throw new EditConflictException(EditingText.NoImage);
        return Encode(stream.Dictionary, Document.RawData(stream), stream);
    }

    private ExtractedImage Encode(PdfDictionary dictionary, byte[] raw, PdfStream? stream)
    {
        try
        {
            var filter = Document.Resolve(dictionary["Filter"] ?? dictionary["F"]);
            var parms = Document.Resolve(dictionary["DecodeParms"] ?? dictionary["DP"]);
            var decoded = PdfFilters.DecodeToCodec(raw, filter, parms);
            switch (decoded.Codec)
            {
                case "DCTDecode":
                    return new ExtractedImage(decoded.Data, "jpg");
                case "JPXDecode":
                    return new ExtractedImage(decoded.Data, "jp2");
                case "JBIG2Decode":
                    if (Codec?.Decode(decoded.Data, "JBIG2Decode") is { } bits) return new ExtractedImage(PngWriter.Encode(bits), "png");
                    break;
                default:
                    var rgba = PdfImageSamples.ToRgba(dictionary, decoded.Data, Document.Resolve, s => Document.Data(s));
                    return new ExtractedImage(PngWriter.Encode(rgba), "png");
            }
        }
        catch (PdfReadException)
        {
        }
        throw new EditConflictException(EditingText.NoImage);
    }

    /// <summary>Moves a picture or path in front of or behind the next object in the stream, when it sits in a q ... Q of its own.</summary>
    public void Order(PageObject o, OrderMove move)
    {
        var unit = o.Unit;
        var place = PlaceOf(o);
        var ops = unit.Operations;
        var states = unit.States;
        int paint = o is ImageObject image ? image.Op : ((PathObject)o).PaintOp;
        int first = o is PathObject path ? path.FirstOp : paint;
        int d = states.At(first).Depth;
        if (d == 0) throw new EditConflictException(EditingText.NotAlone);
        int open = -1;
        for (int j = first - 1; j >= 0; j--)
        {
            if (states.At(j).Depth < d)
            {
                open = j;
                break;
            }
        }
        int close = Closing(unit, paint + 1, d);
        if (open < 0 || ops[open].Operator != "q" || close < 0) throw new EditConflictException(EditingText.NotAlone);
        if (Enumerable.Range(open + 1, close - open - 1).Count(i => IsPainting(ops[i])) != 1) throw new EditConflictException(EditingText.NotAlone);

        List<(int First, int Last)> siblings;
        int me;
        while (true)
        {
            int parentStart = 0, parentEnd = ops.Count;
            if (d > 1)
            {
                for (int j = open - 1; j >= 0; j--)
                {
                    if (states.At(j).Depth < d - 1)
                    {
                        parentStart = j + 1;
                        break;
                    }
                }
                int end = Closing(unit, close + 1, d - 1);
                if (end >= 0) parentEnd = end;
            }
            siblings = Siblings(unit, d - 1, parentStart, parentEnd);
            me = siblings.FindIndex(s => s.First == open);
            // A group that is all its parent holds moves with the parent.
            if (siblings.Count == 1 && d > 1 && parentStart > 0 && parentEnd < ops.Count && ops[parentStart - 1].Operator == "q")
            {
                (open, close) = (parentStart - 1, parentEnd);
                d--;
                continue;
            }
            break;
        }
        int target = move switch
        {
            OrderMove.Forward => me + 1,
            OrderMove.Backward => me - 1,
            OrderMove.Front => siblings.Count - 1,
            _ => 0,
        };
        if (me < 0 || target == me || target < 0 || target >= siblings.Count) throw new EditConflictException(EditingText.AlreadyThere);
        bool after = target > me;
        if (!(after ? Crossable(unit, close + 1, siblings[target].Last) : Crossable(unit, siblings[target].First, open - 1))) throw new EditConflictException(EditingText.StateBetween);
        int at = after ? ops[siblings[target].Last].End : ops[siblings[target].First].Start;
        string group = Encoding.Latin1.GetString(unit.Data, ops[open].Start, ops[close].End - ops[open].Start);
        Replace(place, ops[open].Start, ops[close].End, "");
        Insert(place, at, after ? "\n" + group : group + "\n");
    }

    // Operators that only build or paint: a group can jump over them. A setting or clip it would meet, or
    // marked content it would leave, changes how it is drawn and which layer or structure element owns it (8.4, 14.6).
    private static readonly HashSet<string> Inert =
    [
        "m", "l", "c", "v", "y", "h", "re", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n", "Do", "sh", "BI",
        "BT", "ET", "Td", "TD", "Tm", "T*", "Tj", "TJ", "'", "\"", "Tf", "Tc", "Tw", "Tz", "TL", "Tr", "Ts", "MP", "DP",
    ];

    private static bool Crossable(ContentUnit unit, int from, int to)
    {
        var ops = unit.Operations;
        for (int i = from; i <= to && i < ops.Count; i++)
        {
            if (ops[i].Operator == "q")
            {
                i = Closing(unit, i + 1, unit.States.At(i).Depth + 1);
                if (i < 0) return false;
            }
            else if (!Inert.Contains(ops[i].Operator) || AddsToClip(unit, i)) return false;
        }
        return true;
    }

    // Text shown in render mode 4 to 7 joins the clip at ET (9.3.6), so a group moved past it is clipped differently.
    private static bool AddsToClip(ContentUnit unit, int index) =>
        unit.Operations[index].Operator is "Tj" or "TJ" or "'" or "\"" &&
        unit.States.At(index).Mode is { Operands: [PdfNumber { Value: >= 4 and <= 7 }] };

    private static int Closing(ContentUnit unit, int from, int depth)
    {
        for (int k = from; k < unit.Operations.Count; k++)
        {
            if (unit.Operations[k].Operator == "Q" && unit.States.At(k).Depth == depth) return k;
        }
        return -1;
    }

    // The things painted at one level of q nesting, in order, as ranges of operations.
    private static List<(int First, int Last)> Siblings(ContentUnit unit, int level, int from, int to)
    {
        var ops = unit.Operations;
        var states = unit.States;
        var found = new List<(int First, int Last)>();
        for (int i = from; i < to; i++)
        {
            if (states.At(i).Depth != level) continue;
            string op = ops[i].Operator;
            if (op == "q")
            {
                int m = Closing(unit, i + 1, level + 1);
                if (m < 0 || m >= to) break;
                if (Enumerable.Range(i + 1, m - i - 1).Any(k => IsPainting(ops[k]))) found.Add((i, m));
                i = m;
            }
            else if (op == "BT")
            {
                int e = i + 1;
                while (e < to && ops[e].Operator != "ET") e++;
                if (Enumerable.Range(i + 1, Math.Max(0, e - i - 1)).Any(k => IsPainting(ops[k]))) found.Add((i, Math.Min(e, to - 1)));
                i = e;
            }
            else if (IsPainting(ops[i]) && op is not ("Tj" or "TJ" or "'" or "\""))
            {
                int start = i;
                while (start > from && ops[start - 1].Operator is "m" or "l" or "c" or "v" or "y" or "h" or "re" or "W" or "W*") start--;
                found.Add((start, i));
            }
        }
        return found;
    }
}
