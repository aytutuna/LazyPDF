using System.Text;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A scanned form drawn by Windows.Data.Pdf and read for blanks, on a page as it comes and turned a quarter.
public sealed class ScanFormTests
{
    private const int Width = 600, Height = 800;

    // A 300 by 400 point page holding one grey picture: two ruled lines, a check box and a box. With rotate 90 the
    // picture lies on its side on a 400 by 300 page that the viewer turns upright, as a sheet fed in sideways comes out.
    private static byte[] ScanPdf(int rotate)
    {
        var pixels = new byte[Width * Height];
        Array.Fill(pixels, (byte)245);
        void Ink(int x1, int y1, int x2, int y2)
        {
            for (int y = y1; y < y2; y++)
            {
                for (int x = x1; x < x2; x++) pixels[y * Width + x] = 20;
            }
        }
        void Box(int x, int y, int w, int h)
        {
            Ink(x, y, x + w, y + 3);
            Ink(x, y + h - 3, x + w, y + h);
            Ink(x, y, x + 3, y + h);
            Ink(x + w - 3, y, x + w, y + h);
        }
        Ink(150, 200, 500, 203);
        Ink(150, 300, 500, 303);
        Box(150, 380, 30, 30);
        Box(150, 480, 350, 60);

        int width = Width, height = Height;
        if (rotate == 90)
        {
            var side = new byte[pixels.Length];
            for (int y = 0; y < Width; y++)
            {
                for (int x = 0; x < Height; x++) side[y * Height + x] = pixels[x * Width + (Width - 1 - y)];
            }
            pixels = side;
            (width, height) = (Height, Width);
        }

        var file = new MemoryStream();
        var offsets = new List<long>();
        void Write(string text) => file.Write(Encoding.Latin1.GetBytes(text));
        void Object(int number, string body)
        {
            offsets.Add(file.Position);
            Write($"{number} 0 obj\n{body}\nendobj\n");
        }
        Write("%PDF-1.4\n");
        Object(1, "<</Type /Catalog /Pages 2 0 R>>");
        Object(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>");
        Object(3, $"<</Type /Page /Parent 2 0 R /MediaBox [0 0 {(rotate == 90 ? "400 300" : "300 400")}] /Rotate {rotate} /Contents 4 0 R /Resources <</XObject <</Im1 5 0 R>>>>>>");
        string content = rotate == 90 ? "q 400 0 0 300 0 0 cm /Im1 Do Q" : "q 300 0 0 400 0 0 cm /Im1 Do Q";
        Object(4, $"<</Length {content.Length}>>\nstream\n{content}\nendstream");
        offsets.Add(file.Position);
        Write($"5 0 obj\n<</Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Length {pixels.Length}>>\nstream\n");
        file.Write(pixels);
        Write("\nendstream\nendobj\n");
        long xref = file.Position;
        Write($"xref\n0 6\n0000000000 65535 f \n{string.Concat(offsets.Select(o => $"{o:D10} 00000 n \n"))}trailer\n<</Size 6 /Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n");
        return file.ToArray();
    }

    // The proposals as the viewer shows them, in points from the top left of the page.
    private static List<DisplayRect> Found(int rotate, out IReadOnlyList<FieldProposal> proposals)
    {
        var session = PdfEditSession.Open(ScanPdf(rotate));
        using var renderer = new WindowsPageRenderer();
        Assert.True(renderer.Load(session, null));
        proposals = FieldDetector.Detect(session.Document, renderer);
        var geometry = new PageGeometry(session.Document.Pages[0]);
        return [.. proposals.Select(p => geometry.ToDisplay(p.Rect)).OrderBy(d => d.Y).ThenBy(d => d.X)];
    }

    [Fact]
    public void TheLinesTheCheckBoxAndTheBoxOfAScanAreFound()
    {
        Found(0, out var found);

        Assert.Equal(2, found.Count(p => p.Kind == FieldKind.Text && p.Rect.Height < 30));
        Assert.Single(found, p => p.Kind == FieldKind.CheckBox);
        Assert.Single(found, p => p.Kind == FieldKind.Text && p.Rect.Height > 25);
        Assert.All(found, p => Assert.True(p.FromPixels));
        var line = found.Where(p => p.Rect.Height < 30).OrderByDescending(p => p.Rect.Top).First();
        // The picture is 600 pixels over 300 points; the upper line is 100 points down the page, above 175 to 250 points across.
        Assert.InRange(line.Rect.Left, 73, 77);
        Assert.InRange(line.Rect.Right, 248, 252);
        Assert.InRange(line.Rect.Bottom, 300, 302);
    }

    [Fact]
    public void ASidewaysScanTurnedUprightGivesTheSameFieldsInTheSamePlaces()
    {
        var upright = Found(0, out _);
        var turned = Found(90, out _);

        Assert.Equal(4, upright.Count);
        Assert.Equal(upright.Count, turned.Count);
        for (int i = 0; i < upright.Count; i++)
        {
            Assert.InRange(Math.Abs(upright[i].X - turned[i].X), 0, 2);
            Assert.InRange(Math.Abs(upright[i].Y - turned[i].Y), 0, 2);
            Assert.InRange(Math.Abs(upright[i].Width - turned[i].Width), 0, 2);
            Assert.InRange(Math.Abs(upright[i].Height - turned[i].Height), 0, 2);
        }
    }
}
