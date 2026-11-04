namespace LazyPDF.Core;

/// <summary>
/// The parser and the interpreter bound the q stack, the size of a path, the operands of an operator and
/// the depth of marked content, and carry on without saying so: a restore past the bound does not restore,
/// the rest of a long path or a long operand list is dropped and a deep sequence is not reported. Content
/// that does any of this is placed or read wrongly by the scan, so it counts as content that cannot be followed.
/// </summary>
internal static class RedactionLimits
{
    private const int MaxStack = 256;
    private const int MaxOperands = 512;
    private const int MaxMarked = 1024;
    private const long MaxSegments = 1_000_000;
    private const int MaxFormOperations = 1_000_000;
    private const long MaxFormSize = 64L << 20;

    public static bool Exceeded(IReadOnlyList<ContentOperation> operations)
    {
        int depth = 0, marked = 0;
        long segments = 0;
        foreach (var op in operations)
        {
            // The parser keeps the first operands; a show operator would take its string from the wrong one.
            if (op.Operands.Count >= MaxOperands) return true;
            switch (op.Operator)
            {
                case "q" when ++depth > MaxStack:
                    return true;
                case "Q":
                    depth = Math.Max(0, depth - 1);
                    break;
                case "BMC" or "BDC" when ++marked > MaxMarked:
                    return true;
                case "EMC":
                    marked = Math.Max(0, marked - 1);
                    break;
                case "m" or "l" or "c" or "v" or "y" or "h":
                    segments++;
                    break;
                case "re":
                    segments += 5;
                    break;
                case "S" or "s" or "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "n":
                    segments = 0;
                    break;
            }
            if (segments > MaxSegments) return true;
        }
        return false;
    }

    /// <summary>The operations of a form or cell as the interpreter reads them; null when it cannot be read, or reads it only in part.</summary>
    public static IReadOnlyList<ContentOperation>? Followable(PdfDocument document, PdfStream form)
    {
        try
        {
            var operations = ContentParser.Parse(document.Data(form, MaxFormSize), MaxFormOperations);
            return Exceeded(operations) ? null : operations;
        }
        catch (PdfReadException)
        {
            return null;
        }
    }
}
