using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

// Type 4 functions (ISO 32000-1 7.10.5): a subset of PostScript with no loops, so a program
// runs in time proportional to its size.
public abstract partial class PdfFunction
{
    private sealed class PostScript : PdfFunction
    {
        private const int StackSize = 100, MaxNesting = 32;

        private enum Code
        {
            Push, Abs, Add, Atan, Ceiling, Cos, Cvi, Cvr, Div, Exp, Floor, Idiv, Ln, Log, Mod, Mul, Neg, Round, Sin, Sqrt, Sub, Truncate,
            And, Bitshift, Eq, False, Ge, Gt, Le, Lt, Ne, Not, Or, True, Xor,
            Copy, Dup, Exch, Index, Pop, Roll, If, IfElse,
        }

        private readonly record struct Op(Code Code, double Value = 0, Op[]? Body = null, Op[]? Else = null);

        private struct Value
        {
            public double Number;
            public bool IsBoolean;
        }

        private static readonly Dictionary<string, Code> Words = Enum.GetValues<Code>()
            .Where(c => c is not (Code.Push or Code.If or Code.IfElse))
            .ToDictionary(c => c.ToString().ToLowerInvariant());

        private Op[] _program = [];

        public static PostScript Create(PdfStream? stream, double[] domain, double[]? range, Func<PdfStream, byte[]> decodeStream)
        {
            if (stream is null || range is null || range.Length < 2) throw PdfReadException.Damaged("A type 4 function needs a stream and a /Range.");
            var text = decodeStream(stream);
            int at = 0;
            SkipSpace(text, ref at);
            if (at >= text.Length || text[at] != '{') throw PdfReadException.Damaged("A type 4 function does not start with a brace.");
            at++;
            var program = ParseBlock(text, ref at, 0);
            return new PostScript { _program = program, Inputs = domain.Length / 2, Outputs = range.Length / 2 };
        }

        private static Op[] ParseBlock(byte[] text, ref int at, int depth)
        {
            if (depth > MaxNesting) throw PdfReadException.Damaged("A type 4 function nests too deep.");
            var ops = new List<Op>();
            var blocks = new List<Op[]>();
            while (true)
            {
                SkipSpace(text, ref at);
                if (at >= text.Length) throw PdfReadException.Damaged("A type 4 function is not closed.");
                byte b = text[at];
                if (b == '}')
                {
                    at++;
                    return [.. ops];
                }
                if (b == '{')
                {
                    at++;
                    blocks.Add(ParseBlock(text, ref at, depth + 1));
                    continue;
                }
                int start = at;
                while (at < text.Length && !PdfLexer.IsWhiteSpace(text[at]) && text[at] is not ((byte)'{' or (byte)'}' or (byte)'%')) at++;
                var word = Encoding.ASCII.GetString(text, start, at - start);
                if (double.TryParse(word, NumberStyles.Float, CultureInfo.InvariantCulture, out double number))
                {
                    ops.Add(new Op(Code.Push, number));
                }
                else if (word == "if" && blocks.Count >= 1)
                {
                    ops.Add(new Op(Code.If, Body: blocks[^1]));
                    blocks.Clear();
                }
                else if (word == "ifelse" && blocks.Count >= 2)
                {
                    ops.Add(new Op(Code.IfElse, Body: blocks[^2], Else: blocks[^1]));
                    blocks.Clear();
                }
                else if (Words.TryGetValue(word, out var code))
                {
                    ops.Add(new Op(code));
                }
                else
                {
                    throw PdfReadException.Damaged($"A type 4 function uses \"{word}\".");
                }
            }
        }

        private static void SkipSpace(byte[] text, ref int at)
        {
            while (at < text.Length)
            {
                if (PdfLexer.IsWhiteSpace(text[at])) at++;
                else if (text[at] == '%') while (at < text.Length && text[at] is not ((byte)'\n' or (byte)'\r')) at++;
                else break;
            }
        }

        private protected override void Compute(ReadOnlySpan<double> input, Span<double> output)
        {
            Span<Value> stack = stackalloc Value[StackSize];
            int top = 0;
            foreach (double x in input) stack[top++] = new Value { Number = x };
            Run(_program, stack, ref top);
            if (top < Outputs) throw PdfReadException.Damaged("A type 4 function leaves too few results.");
            for (int i = 0; i < Outputs; i++) output[i] = stack[top - Outputs + i].Number;
        }

        private static void Run(Op[] ops, Span<Value> s, ref int top)
        {
            foreach (var op in ops)
            {
                switch (op.Code)
                {
                    case Code.Push: Need(0, top, 1); s[top++] = new Value { Number = op.Value }; break;
                    case Code.True: Need(0, top, 1); s[top++] = new Value { Number = 1, IsBoolean = true }; break;
                    case Code.False: Need(0, top, 1); s[top++] = new Value { IsBoolean = true }; break;
                    case Code.If:
                        Need(1, top, 0);
                        if (s[--top].Number != 0) Run(op.Body!, s, ref top);
                        break;
                    case Code.IfElse:
                        Need(1, top, 0);
                        Run(s[--top].Number != 0 ? op.Body! : op.Else!, s, ref top);
                        break;
                    case Code.Pop: Need(1, top, 0); top--; break;
                    case Code.Dup: Need(1, top, 1); s[top] = s[top - 1]; top++; break;
                    case Code.Exch: Need(2, top, 0); (s[top - 1], s[top - 2]) = (s[top - 2], s[top - 1]); break;
                    case Code.Copy:
                    {
                        Need(1, top, 0);
                        int n = (int)s[--top].Number;
                        if (n < 0 || n > top || top + n > StackSize) throw Overflow();
                        for (int i = 0; i < n; i++) s[top + i] = s[top - n + i];
                        top += n;
                        break;
                    }
                    case Code.Index:
                    {
                        Need(1, top, 0);
                        int n = (int)s[top - 1].Number;
                        if (n < 0 || n >= top - 1) throw Overflow();
                        s[top - 1] = s[top - 2 - n];
                        break;
                    }
                    case Code.Roll:
                    {
                        Need(2, top, 0);
                        int j = (int)s[--top].Number;
                        int n = (int)s[--top].Number;
                        if (n < 0 || n > top) throw Overflow();
                        if (n > 1) Roll(s.Slice(top - n, n), j);
                        break;
                    }
                    case Code.Abs or Code.Ceiling or Code.Cos or Code.Cvi or Code.Cvr or Code.Floor or Code.Ln or Code.Log or Code.Neg
                        or Code.Round or Code.Sin or Code.Sqrt or Code.Truncate or Code.Not:
                        Need(1, top, 0);
                        s[top - 1] = Unary(op.Code, s[top - 1]);
                        break;
                    default:
                        Need(2, top, 0);
                        s[top - 2] = Binary(op.Code, s[top - 2], s[top - 1]);
                        top--;
                        break;
                }
            }
        }

        private static void Need(int required, int top, int push)
        {
            if (top < required) throw PdfReadException.Damaged("A type 4 function pops an empty stack.");
            if (top + push > StackSize) throw Overflow();
        }

        private static PdfReadException Overflow() => PdfReadException.Damaged("A type 4 function breaks the stack limits.");

        private static void Roll(Span<Value> part, int j)
        {
            j %= part.Length;
            if (j < 0) j += part.Length;
            if (j == 0) return;
            part[^j..].Reverse();
            part[..^j].Reverse();
            part.Reverse();
        }

        private static Value Unary(Code code, Value v)
        {
            double x = v.Number;
            if (code == Code.Not) return v.IsBoolean ? Flag(x == 0) : new Value { Number = ~(long)x };
            return new Value
            {
                Number = code switch
                {
                    Code.Abs => Math.Abs(x),
                    Code.Ceiling => Math.Ceiling(x),
                    Code.Cos => Math.Cos(x * Math.PI / 180),
                    Code.Cvi or Code.Truncate => Math.Truncate(x),
                    Code.Floor => Math.Floor(x),
                    Code.Ln => Math.Log(x),
                    Code.Log => Math.Log10(x),
                    Code.Neg => -x,
                    Code.Round => Math.Floor(x + 0.5),
                    Code.Sin => Math.Sin(x * Math.PI / 180),
                    Code.Sqrt => Math.Sqrt(x),
                    _ => x,
                },
            };
        }

        private static Value Binary(Code code, Value a, Value b)
        {
            double x = a.Number, y = b.Number;
            bool logical = a.IsBoolean && b.IsBoolean;
            switch (code)
            {
                case Code.Eq: return Flag(x == y);
                case Code.Ne: return Flag(x != y);
                case Code.Gt: return Flag(x > y);
                case Code.Ge: return Flag(x >= y);
                case Code.Lt: return Flag(x < y);
                case Code.Le: return Flag(x <= y);
                case Code.And: return logical ? Flag(x != 0 && y != 0) : new Value { Number = (long)x & (long)y };
                case Code.Or: return logical ? Flag(x != 0 || y != 0) : new Value { Number = (long)x | (long)y };
                case Code.Xor: return logical ? Flag((x != 0) != (y != 0)) : new Value { Number = (long)x ^ (long)y };
            }
            double result = code switch
            {
                Code.Add => x + y,
                Code.Sub => x - y,
                Code.Mul => x * y,
                Code.Div => y == 0 ? 0 : x / y,
                Code.Idiv => (long)y switch { 0 => 0, -1 => -(double)(long)x, var d => (long)x / d },
                Code.Mod => (long)y is 0 or -1 ? 0 : (long)x % (long)y,
                Code.Exp => Math.Pow(x, y),
                Code.Atan => Atan(x, y),
                Code.Bitshift => y >= 0 ? (long)x << (int)Math.Min(y, 62) : (long)x >> (int)Math.Min(-y, 62),
                _ => 0,
            };
            return new Value { Number = result };
        }

        private static Value Flag(bool on) => new() { Number = on ? 1 : 0, IsBoolean = true };

        private static double Atan(double numerator, double denominator)
        {
            double degrees = Math.Atan2(numerator, denominator) * 180 / Math.PI;
            return degrees < 0 ? degrees + 360 : degrees;
        }
    }
}
