using System.Runtime.CompilerServices;
using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

// Golden files: Tests/Fixtures/golden/<layer>/<name>. C# writes the outputs, Swift reads them and
// must produce the same bytes. Inputs are hand-written text beside them, one case per line, with
// \n \r \t \\ and \xHH standing for the bytes that do not belong in a text file.
internal static class Golden
{
    public static string Input(string layer, string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", layer, name)).ReplaceLineEndings("\n");

    /// <summary>
    /// Compares <paramref name="actual"/> with the golden file. With LAZYPDF_WRITE_GOLDEN=1 the file is
    /// written into the source tree instead (the build copies it on the next run).
    /// </summary>
    public static void Check(string layer, string name, string actual)
    {
        string here = ThisFile();
        byte[] bytes = new UTF8Encoding(false).GetBytes(actual);
        if (Environment.GetEnvironmentVariable("LAZYPDF_WRITE_GOLDEN") == "1")
        {
            string folder = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "Tests", "Fixtures", "golden", layer));
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, name), bytes);
            return;
        }
        byte[] expected = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", layer, name));
        Assert.Equal(Encoding.UTF8.GetString(expected).ReplaceLineEndings("\n"), actual);
    }

    private static string ThisFile([CallerFilePath] string path = "") => path;

    public static byte[] Unescape(string text)
    {
        var bytes = new List<byte>();
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] != '\\')
            {
                bytes.Add((byte)text[i]);
                continue;
            }
            char c = text[++i];
            switch (c)
            {
                case 'n': bytes.Add(10); break;
                case 'r': bytes.Add(13); break;
                case 't': bytes.Add(9); break;
                case 'x':
                    bytes.Add(Convert.ToByte(text.Substring(i + 1, 2), 16));
                    i += 2;
                    break;
                default: bytes.Add((byte)c); break;
            }
        }
        return [.. bytes];
    }

    public static string Escape(string text)
    {
        var sb = new StringBuilder();
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '\n': sb.Append(@"\n"); break;
                case '\r': sb.Append(@"\r"); break;
                case '\t': sb.Append(@"\t"); break;
                default:
                    if (c < 0x20 || c >= 0x7F) sb.Append(@"\x").Append(((int)c & 0xFF).ToString("x2"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    public static string Escape(byte[] bytes) => Escape(Encoding.Latin1.GetString(bytes));
}
