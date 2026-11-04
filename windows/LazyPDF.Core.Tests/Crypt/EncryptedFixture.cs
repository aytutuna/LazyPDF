using System.Text;
using System.Text.RegularExpressions;

namespace LazyPDF.Core.Tests;

/// <summary>An encrypted fixture file reduced to what the security handler needs: /Encrypt, the first /ID and the page's content stream (object 4).</summary>
internal sealed record EncryptedFixture(PdfDictionary Encrypt, byte[] Id, PdfDictionary ContentDictionary, byte[] Content)
{
    public const string PlainContent = "1 0 0 rg 0 0 612 792 re f\n";

    public static EncryptedFixture Load(string name)
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "Documents", name);
        byte[] bytes = File.ReadAllBytes(path);
        string text = Encoding.Latin1.GetString(bytes);
        byte[] id = Convert.FromHexString(Regex.Match(text, @"/ID \[ <([0-9a-f]+)>").Groups[1].Value);
        int number = int.Parse(Regex.Match(text, @"/Encrypt (\d+) 0 R").Groups[1].Value);
        var encrypt = (PdfDictionary)ObjectAt(bytes, text, number);
        var content = (PdfStream)ObjectAt(bytes, text, 4);
        int length = (int)((PdfNumber)content.Dictionary["Length"]!).Integer!.Value;
        return new(encrypt, id, content.Dictionary, new PdfArrayBytes(bytes).Read(content.DataOffset, length));
    }

    private static PdfObject ObjectAt(byte[] bytes, string text, int number)
    {
        int at = text.IndexOf($"\n{number} 0 obj", StringComparison.Ordinal) + 1;
        var lexer = new PdfLexer(new PdfArrayBytes(bytes), at);
        lexer.ReadObjectHeader();
        return lexer.ReadObject();
    }
}
