namespace LazyPDF.Core;

internal sealed partial class AppearanceBuilder
{
    // The system renderer draws its own icon for a note and ignores this one; other viewers use it.
    private AppearanceCanvas Note(PdfAnnotation a)
    {
        var c = Canvas(a);
        double w = a.Rect.Width, h = a.Rect.Height;
        c.Transparency(a.Opacity, multiply: false);
        c.Color(a.Color ?? Yellow, stroke: false);
        c.Color(Black, stroke: true);
        c.W.LineWidth(Math.Max(0.5, Math.Min(w, h) / 24));
        if (a.IconName == "Comment")
        {
            double m = 0.5;
            c.W.MoveTo(m, h * 0.3).LineTo(m, h - m).LineTo(w - m, h - m).LineTo(w - m, h * 0.3).LineTo(w * 0.55, h * 0.3)
                .LineTo(w * 0.25, m).LineTo(w * 0.3, h * 0.3).Close().FillAndStroke();
            return c;
        }
        c.W.Rect(0.5, 0.5, w - 1, h - 1).FillAndStroke();
        if (NoteGlyph(c, a.IconName, w, h)) return c;
        for (int i = 0; i < 3; i++)
        {
            double y = h * (0.72 - 0.2 * i);
            c.W.MoveTo(w * 0.2, y).LineTo(w * 0.8, y).Stroke();
        }
        return c;
    }

    private bool NoteGlyph(AppearanceCanvas c, string? name, double w, double h)
    {
        switch (name)
        {
            case "Help":
                c.W.MoveTo(w * 0.35, h * 0.68).CurveTo(w * 0.35, h * 0.88, w * 0.65, h * 0.88, w * 0.65, h * 0.68)
                    .CurveTo(w * 0.65, h * 0.55, w * 0.5, h * 0.52, w * 0.5, h * 0.38).Stroke();
                c.Color(Black, stroke: false);
                c.W.Rect(w * 0.45, h * 0.16, w * 0.1, h * 0.1).Fill();
                return true;
            case "Insert":
                c.W.MoveTo(w * 0.2, h * 0.2).LineTo(w * 0.5, h * 0.8).LineTo(w * 0.8, h * 0.2).Stroke();
                return true;
            case "Key":
                c.W.MoveTo(w * 0.15, h * 0.5).LineTo(w * 0.3, h * 0.67).LineTo(w * 0.45, h * 0.5).LineTo(w * 0.3, h * 0.33).Close().Stroke();
                c.W.MoveTo(w * 0.45, h * 0.5).LineTo(w * 0.85, h * 0.5).Stroke();
                c.W.MoveTo(w * 0.68, h * 0.5).LineTo(w * 0.68, h * 0.32).Stroke();
                c.W.MoveTo(w * 0.82, h * 0.5).LineTo(w * 0.82, h * 0.32).Stroke();
                return true;
            case "NewParagraph":
                c.W.MoveTo(w * 0.75, h * 0.8).LineTo(w * 0.75, h * 0.4).LineTo(w * 0.35, h * 0.4).Stroke();
                c.Color(Black, stroke: false);
                c.W.MoveTo(w * 0.18, h * 0.4).LineTo(w * 0.38, h * 0.58).LineTo(w * 0.38, h * 0.22).Close().Fill();
                return true;
            case "Paragraph":
                c.W.MoveTo(w * 0.7, h * 0.8).LineTo(w * 0.45, h * 0.8).CurveTo(w * 0.2, h * 0.8, w * 0.2, h * 0.46, w * 0.45, h * 0.46)
                    .LineTo(w * 0.55, h * 0.46).Stroke();
                c.W.MoveTo(w * 0.55, h * 0.2).LineTo(w * 0.55, h * 0.8).Stroke();
                c.W.MoveTo(w * 0.7, h * 0.2).LineTo(w * 0.7, h * 0.8).Stroke();
                return true;
            default:
                return false;
        }
    }

    private AppearanceCanvas Caret(PdfAnnotation a)
    {
        var c = Canvas(a);
        double w = a.Rect.Width, h = a.Rect.Height;
        c.Transparency(a.Opacity, multiply: false);
        if (!c.Color(a.Color ?? Black, stroke: false)) return c;
        c.W.MoveTo(0, 0).CurveTo(w * 0.35, 0, w * 0.5, h * 0.4, w * 0.5, h).CurveTo(w * 0.5, h * 0.4, w * 0.65, 0, w, 0).Close().Fill();
        return c;
    }

    private AppearanceCanvas Attachment(PdfAnnotation a)
    {
        var c = Canvas(a);
        double w = a.Rect.Width, h = a.Rect.Height;
        c.Transparency(a.Opacity, multiply: false);
        c.Color(a.Color ?? [0.3, 0.3, 0.35], stroke: true);
        c.Color(a.Color ?? [0.3, 0.3, 0.35], stroke: false);
        c.W.LineWidth(Math.Max(0.75, Math.Min(w, h) / 10)).Raw("1 J 1 j");
        switch (a.IconName)
        {
            case "Paperclip":
                c.W.MoveTo(w * 0.35, h * 0.15).LineTo(w * 0.35, h * 0.85).LineTo(w * 0.7, h * 0.85).LineTo(w * 0.7, h * 0.25)
                    .LineTo(w * 0.52, h * 0.25).LineTo(w * 0.52, h * 0.7).Stroke();
                break;
            case "Graph":
                for (int i = 0; i < 3; i++) c.W.Rect(w * (0.12 + 0.3 * i), h * 0.1, w * 0.22, h * (0.3 + 0.2 * i)).Fill();
                break;
            case "Tag":
                c.W.MoveTo(w * 0.1, h * 0.55).LineTo(w * 0.45, h * 0.9).LineTo(w * 0.9, h * 0.9).LineTo(w * 0.9, h * 0.45)
                    .LineTo(w * 0.55, h * 0.1).Close().Fill();
                break;
            default:
                c.W.MoveTo(w * 0.2, h * 0.2).LineTo(w * 0.5, h * 0.5).Stroke();
                c.W.MoveTo(w * 0.45, h * 0.35).LineTo(w * 0.65, h * 0.35).LineTo(w * 0.85, h * 0.55).LineTo(w * 0.85, h * 0.65)
                    .LineTo(w * 0.35, h * 0.65).LineTo(w * 0.35, h * 0.55).Close().Fill();
                break;
        }
        return c;
    }

    // Only the mark: an outline round the area to remove. The area itself is blanked by a later layer.
    private AppearanceCanvas Redact(PdfAnnotation a)
    {
        var c = Canvas(a);
        c.Transparency(a.Opacity, multiply: false);
        if (!c.Color(a.Color ?? Red, stroke: true)) return c;
        c.Stroke(1.5, null);
        if (a.Quads.Count == 0)
        {
            c.W.Rect(0.75, 0.75, a.Rect.Width - 1.5, a.Rect.Height - 1.5).Stroke();
            return c;
        }
        foreach (var q in a.Quads)
        {
            c.Move(q.X1, q.Y1).Line(q.X2, q.Y2).Line(q.X4, q.Y4).Line(q.X3, q.Y3);
            c.W.Close().Stroke();
        }
        return c;
    }
}
