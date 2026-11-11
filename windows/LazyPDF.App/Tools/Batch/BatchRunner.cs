using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Ocr;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Batch;

/// <param name="Output">Where the result was written; null when the file failed.</param>
public sealed record BatchResult(string Input, string? Output, bool Ok, string Title, string Detail);

/// <summary>
/// Runs a set's steps over one file at a time and writes the result under a new name in the output folder. The
/// source is only read, and a result never replaces a file that is already there. A Bates step moves its own
/// <see cref="BatchStep.Start"/> on to the number after the last page, so the set it is given carries the count.
/// </summary>
internal sealed class BatchRunner(IImageCodec codec, IFontSource fonts, ITextRecognizer recognizer, Func<IDocumentRenderer> renderers)
{
    public async Task<BatchResult> RunAsync(string path, BatchSet set, int number, DateTimeOffset now, CancellationToken cancellation, string relativeDir = "", string? password = null)
    {
        string name = Path.GetFileName(path);
        byte[] bytes;
        var notes = new List<string>();
        try
        {
            bytes = await File.ReadAllBytesAsync(path, cancellation);
            PdfDocument source;
            bool unlocked = false;
            try
            {
                source = PdfDocument.Open(bytes);
            }
            catch (PdfReadException e) when (e.Problem == PdfReadProblem.PasswordRequired && !string.IsNullOrEmpty(password))
            {
                source = PdfDocument.Open(bytes, password);
                unlocked = true;
            }
            using (source)
            {
                if (source.IsSigned) return new(path, null, false, Loc.T("File is signed"), Loc.T("{0} has a signature that these steps would break. Open it and sign it again afterwards.", name));
                if (source.Security is { OpenedAsOwner: false, Permissions: not PdfPermissions.All })
                    return new(path, null, false, Loc.T("File is protected"), Loc.T("{0} limits what may be done to it. Ask its owner for a copy without limits.", name));
                // Every step reopens the bytes with no password.
                if (unlocked) bytes = source.SaveRewrite();
            }
            for (int i = 0; i < set.Steps.Count; i++)
            {
                cancellation.ThrowIfCancellationRequested();
                bytes = await ApplyAsync(set.Steps[i], i == set.Steps.Count - 1, bytes, now, notes, cancellation);
            }
            cancellation.ThrowIfCancellationRequested();
            CheckPdfA(set, bytes, notes);
        }
        catch (StepFailed failed)
        {
            return new(path, null, false, failed.Problem.Title, failed.Problem.Text);
        }
        catch (PdfReadException e) when (e.Problem == PdfReadProblem.PasswordRequired && !string.IsNullOrEmpty(password))
        {
            return new(path, null, false, Loc.T("File is locked"), Loc.T("The password does not open {0}.", name));
        }
        catch (PdfReadException e) when (e.Problem is PdfReadProblem.PasswordRequired or PdfReadProblem.CertificateRequired)
        {
            return new(path, null, false, Loc.T("File is locked"), Loc.T("{0} needs a password or certificate, and Batch cannot ask for one. Take the lock off first, then add the file again.", name));
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            var problem = Problems.Open(e, name);
            return new(path, null, false, problem.Title, problem.Text);
        }

        if (relativeDir.StartsWith("..") || Path.IsPathRooted(relativeDir)) relativeDir = "";
        string target = Unique(Path.Combine(set.OutputFolder, relativeDir, BatchNames.Apply(set.NameTemplate, Path.GetFileNameWithoutExtension(path), number, now)));
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            PdfFileSaver.Save(target, bytes);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            var problem = Problems.Save(e, Path.GetFileName(target));
            return new(path, null, false, problem.Title, problem.Text);
        }
        return new(path, target, true, notes.Count == 0 ? Loc.T("Done") : Loc.T("Done, with notes"), string.Join(" ", [Path.GetRelativePath(set.OutputFolder, target), .. notes]));
    }

    private async Task<byte[]> ApplyAsync(BatchStep step, bool last, byte[] bytes, DateTimeOffset now, List<string> notes, CancellationToken cancellation)
    {
        switch (step.Kind)
        {
            case BatchStepKind.Ocr:
                return await OcrAsync(step, bytes, notes, cancellation);
            case BatchStepKind.Compress:
                {
                    using var document = PdfDocument.Open(bytes);
                    // Keeps the file's own encryption, as Make smaller does.
                    var options = OptimizeOptions.For(step.Preset) with { Security = document.Security, DocumentId = document.Security is null ? null : document.FirstId };
                    var result = new PdfOptimizer(document, codec).Run(options);
                    cancellation.ThrowIfCancellationRequested();
                    if (result.Bytes.Length >= bytes.Length)
                    {
                        notes.Add(Loc.T("Could not be made smaller, so it was left as it was."));
                        return bytes;
                    }
                    notes.AddRange(result.Notes);
                    return result.Bytes;
                }
            case BatchStepKind.Clean:
                {
                    using var document = PdfDocument.Open(bytes);
                    var result = new PdfSanitizer(document).Run(new SanitizeOptions
                    {
                        Comments = !step.KeepComments,
                        FormData = !step.KeepForms,
                        ExternalLinks = !step.KeepLinks,
                        EmbeddedFiles = !step.KeepAttachments,
                    });
                    cancellation.ThrowIfCancellationRequested();
                    if (result.Kept.Count > 0) notes.Add(Loc.Plural(result.Kept.Count, "{0} kind of private data is left in.", "{0} kinds of private data are left in."));
                    return result.Bytes;
                }
            case BatchStepKind.Watermark:
                return Watermark(step, bytes, notes);
            case BatchStepKind.Bates:
                return Bates(step, bytes, notes);
            case BatchStepKind.Rotate:
                return Rotate(step, bytes, notes);
            default:
                {
                    var converted = new PdfAConverter(fonts).Convert(bytes, step.Level, now);
                    cancellation.ThrowIfCancellationRequested();
                    if (converted.Bytes is null) throw new StepFailed(new(Loc.T("Not converted to PDF/A"), converted.Refusal ?? ""));
                    notes.AddRange(converted.Changes);
                    if (last && converted.Remaining.Count > 0) notes.Add(Loc.Plural(converted.Remaining.Count, "{0} PDF/A rule is left.", "{0} PDF/A rules are left."));
                    return converted.Bytes;
                }
        }
    }

    // Steps after PDF/A can undo it, so what is left is counted on the finished file.
    private static void CheckPdfA(BatchSet set, byte[] bytes, List<string> notes)
    {
        int at = set.Steps.FindLastIndex(s => s.Kind == BatchStepKind.PdfA);
        if (at < 0 || at == set.Steps.Count - 1) return;
        using var made = PdfDocument.Open(bytes);
        int left = PdfAValidator.Validate(made, set.Steps[at].Level).Issues.Count;
        if (left > 0) notes.Add(Loc.Plural(left, "{0} PDF/A rule is left.", "{0} PDF/A rules are left."));
    }

    private async Task<byte[]> OcrAsync(BatchStep step, byte[] bytes, List<string> notes, CancellationToken cancellation)
    {
        var session = PdfEditSession.Open(bytes);
        using var renderer = renderers();
        if (!renderer.Load(session, null)) throw new StepFailed(new(Loc.T("Pages cannot be drawn"), Loc.T("Windows cannot draw this file, so its text cannot be read.")));
        var options = new OcrOptions(step.Text.Length == 0 ? "en-US" : step.Text);
        OcrResult result;
        IReadOnlyDictionary<int, int> turns;
        try
        {
            var (read, turned) = await OcrWork.ReadAsync(session.Document, renderer, recognizer, options, null, cancellation);
            result = read.Result;
            turns = turned;
            if (read.Pages.Count > 0)
            {
                int words = OcrWork.Write(session.Document, read.Pages, turns, options.Language);
                result = result with { Words = words, Committed = session.Commit(OcrStatusText.Label) };
            }
        }
        catch (InvalidOperationException e)
        {
            throw new StepFailed(new(Loc.T("Text cannot be read"), e.Message));
        }
        if (result.NotRendered > 0) notes.Add(Loc.Plural(result.NotRendered, "{0} page could not be drawn.", "{0} pages could not be drawn."));
        if (result.NoWords > 0) notes.Add(Loc.Plural(result.NoWords, "No text found on {0} page. Check the language.", "No text found on {0} pages. Check the language."));
        if (turns.Count > 0) notes.Add(Loc.Plural(turns.Count, "{0} page was turned upright.", "{0} pages were turned upright."));
        return session.Current.ToArray();
    }

    private byte[] Watermark(BatchStep step, byte[] bytes, List<string> notes)
    {
        if (step.Text.Trim().Length == 0) throw new StepFailed(new(Loc.T("Watermark has no text"), Loc.T("Type the watermark text in the step, then run again.")));
        var session = PdfEditSession.Open(bytes);
        var spec = new WatermarkSpec
        {
            Text = step.Text,
            Opacity = Math.Clamp(step.Opacity, 5, 100) / 100d,
            Rotation = step.Angle,
            Scale = Math.Clamp(step.Size, 10, 100) / 100d,
            Anchor = step.Anchor,
        };
        Stamp(session, notes, "Watermark", stamper => stamper.AddWatermark(spec));
        return session.Current.ToArray();
    }

    private static byte[] Rotate(BatchStep step, byte[] bytes, List<string> notes)
    {
        var session = PdfEditSession.Open(bytes);
        var pages = Enumerable.Range(0, session.Document.Pages.Count).Where(i => step.Pages switch
        {
            BatchPages.Odd => i % 2 == 0,
            BatchPages.Even => i % 2 == 1,
            _ => true,
        }).ToList();
        if (pages.Count == 0)
        {
            notes.Add(Loc.T("No page matched, so nothing was turned."));
            return bytes;
        }
        PageOperations.Rotate(session.Document, pages, step.Turn);
        session.Commit(Loc.T("Rotate pages"));
        return session.Current.ToArray();
    }

    private byte[] Bates(BatchStep step, byte[] bytes, List<string> notes)
    {
        var session = PdfEditSession.Open(bytes);
        var band = step.Place switch
        {
            BatesPlace.FooterCenter or BatesPlace.HeaderCenter => new HeaderFooterBand(Center: "{bates}"),
            BatesPlace.FooterLeft or BatesPlace.HeaderLeft => new HeaderFooterBand(Left: "{bates}"),
            _ => new HeaderFooterBand(Right: "{bates}"),
        };
        bool header = step.Place >= BatesPlace.HeaderRight;
        var spec = new HeaderFooterSpec
        {
            Header = header ? band : new(),
            Footer = header ? new() : band,
            Bates = new BatesSpec(step.Text, step.Suffix, step.Digits, step.Start),
        };
        var run = Stamp(session, notes, "Bates numbers", stamper => stamper.AddHeaderFooter(spec));
        step.Start = run.NextBates;
        return session.Current.ToArray();
    }

    private StampRun Stamp(PdfEditSession session, List<string> notes, string label, Func<PdfStamper, StampRun> add)
    {
        try
        {
            var run = add(new PdfStamper(session.Document, fonts));
            session.Commit(label);
            if (run.Missing.Count > 0) notes.Add(Loc.T("Some characters are missing"));
            return run;
        }
        catch (InvalidOperationException)
        {
            throw new StepFailed(new(Loc.T("No font for the text"), Loc.T("Use other text, or install a font that has these letters.")));
        }
    }

    // A name that is not taken: "a.pdf", then "a (2).pdf".
    private static string Unique(string path)
    {
        string folder = Path.GetDirectoryName(path)!, stem = Path.GetFileNameWithoutExtension(path);
        for (int i = 2; File.Exists(path); i++) path = Path.Combine(folder, $"{stem} ({i}).pdf");
        return path;
    }

    private sealed class StepFailed(Problem problem) : Exception
    {
        public Problem Problem { get; } = problem;
    }
}
