namespace LazyPDF.Core;

// From Lazy Scan's CcittG4Encoder.cs: the run-length code tables of ITU-T T.4 (tables 2 and 3),
// here turned into lookup tables for decoding.

/// <summary>Modified Huffman run codes, looked up by the next 13 bits of the stream.</summary>
internal static class CcittCodes
{

    private static int[] Table((int Code, int Length)[] terminating, (int Code, int Length)[] makeUp)
    {
        var table = new int[1 << 13];
        void Fill(int run, (int Code, int Length) code)
        {
            int shift = 13 - code.Length;
            for (int i = 0; i < 1 << shift; i++) table[code.Code << shift | i] = run << 4 | code.Length;
        }
        for (int i = 0; i < terminating.Length; i++) Fill(i, terminating[i]);
        for (int i = 0; i < makeUp.Length; i++) Fill((i + 1) * 64, makeUp[i]);
        for (int i = 0; i < ExtendedMakeUp.Length; i++) Fill(1792 + i * 64, ExtendedMakeUp[i]);
        return table;
    }

    /// <summary>White terminating codes, runs 0–63 (T.4 table 2).</summary>
    private static readonly (int Code, int Length)[] WhiteTerminating = Codes(
    [
        "00110101", "000111", "0111", "1000", "1011", "1100", "1110", "1111",
        "10011", "10100", "00111", "01000", "001000", "000011", "110100", "110101",
        "101010", "101011", "0100111", "0001100", "0001000", "0010111", "0000011", "0000100",
        "0101000", "0101011", "0010011", "0100100", "0011000", "00000010", "00000011", "00011010",
        "00011011", "00010010", "00010011", "00010100", "00010101", "00010110", "00010111", "00101000",
        "00101001", "00101010", "00101011", "00101100", "00101101", "00000100", "00000101", "00001010",
        "00001011", "01010010", "01010011", "01010100", "01010101", "00100100", "00100101", "01011000",
        "01011001", "01011010", "01011011", "01001010", "01001011", "00110010", "00110011", "00110100",
    ]);

    /// <summary>Black terminating codes, runs 0–63 (T.4 table 2).</summary>
    private static readonly (int Code, int Length)[] BlackTerminating = Codes(
    [
        "0000110111", "010", "11", "10", "011", "0011", "0010", "00011",
        "000101", "000100", "0000100", "0000101", "0000111", "00000100", "00000111", "000011000",
        "0000010111", "0000011000", "0000001000", "00001100111", "00001101000", "00001101100", "00000110111", "00000101000",
        "00000010111", "00000011000", "000011001010", "000011001011", "000011001100", "000011001101", "000001101000", "000001101001",
        "000001101010", "000001101011", "000011010010", "000011010011", "000011010100", "000011010101", "000011010110", "000011010111",
        "000001101100", "000001101101", "000011011010", "000011011011", "000001010100", "000001010101", "000001010110", "000001010111",
        "000001100100", "000001100101", "000001010010", "000001010011", "000000100100", "000000110111", "000000111000", "000000100111",
        "000000101000", "000001011000", "000001011001", "000000101011", "000000101100", "000001011010", "000001100110", "000001100111",
    ]);

    /// <summary>White make-up codes, runs 64–1728 in steps of 64 (T.4 table 3).</summary>
    private static readonly (int Code, int Length)[] WhiteMakeUp = Codes(
    [
        "11011", "10010", "010111", "0110111", "00110110", "00110111", "01100100", "01100101",
        "01101000", "01100111", "011001100", "011001101", "011010010", "011010011", "011010100", "011010101",
        "011010110", "011010111", "011011000", "011011001", "011011010", "011011011", "010011000", "010011001",
        "010011010", "011000", "010011011",
    ]);

    /// <summary>Black make-up codes, runs 64–1728 in steps of 64 (T.4 table 3).</summary>
    private static readonly (int Code, int Length)[] BlackMakeUp = Codes(
    [
        "0000001111", "000011001000", "000011001001", "000001011011", "000000110011", "000000110100", "000000110101", "0000001101100",
        "0000001101101", "0000001001010", "0000001001011", "0000001001100", "0000001001101", "0000001110010", "0000001110011", "0000001110100",
        "0000001110101", "0000001110110", "0000001110111", "0000001010010", "0000001010011", "0000001010100", "0000001010101", "0000001011010",
        "0000001011011", "0000001100100", "0000001100101",
    ]);

    /// <summary>Extended make-up codes for both colors, runs 1792–2560 in steps of 64 (T.4 table 3).</summary>
    private static readonly (int Code, int Length)[] ExtendedMakeUp = Codes(
    [
        "00000001000", "00000001100", "00000001101", "000000010010", "000000010011", "000000010100", "000000010101",
        "000000010110", "000000010111", "000000011100", "000000011101", "000000011110", "000000011111",
    ]);

    /// <summary>Per 13-bit prefix: the run length shifted left by 4, or'd with the code length; zero for no code.</summary>
    public static readonly int[] White = Table(WhiteTerminating, WhiteMakeUp);
    public static readonly int[] Black = Table(BlackTerminating, BlackMakeUp);

    private static (int Code, int Length)[] Codes(string[] bitStrings) =>
        bitStrings.Select(s => (Convert.ToInt32(s, 2), s.Length)).ToArray();
}
