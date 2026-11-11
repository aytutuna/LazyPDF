namespace LazyPDF.App.Tools.Protect;

public enum Strength { None, Weak, Fair, Good, Strong }

public static class PasswordStrength
{
    private static readonly string[] Common = ["password", "123456", "qwerty", "letmein", "iloveyou", "admin", "welcome", "parola", "sifre", "1234567890", "abcdef"];

    public static Strength Rate(string password)
    {
        if (password.Length == 0) return Strength.None;
        string lower = password.ToLowerInvariant();
        string rest = Common.Aggregate(lower, (left, word) => left.Replace(word, ""));
        if (password.Distinct().Count() < 5 || rest.Distinct().Count() < 5) return Strength.Weak;

        int points = new[] { 8, 12, 16, 20 }.Count(n => password.Length >= n);
        int kinds = new[] { password.Any(char.IsLower), password.Any(char.IsUpper), password.Any(char.IsDigit), password.Any(c => !char.IsLetterOrDigit(c)) }.Count(k => k);
        if (kinds >= 3) points++;
        return points switch
        {
            <= 1 => Strength.Weak,
            2 => Strength.Fair,
            3 => Strength.Good,
            _ => Strength.Strong,
        };
    }

    public static bool VeryShort(string password) => password.Length is > 0 and < 6;

    public static string Hint(Strength strength) => strength switch
    {
        Strength.None => "",
        Strength.Weak => Loc.T("Weak. Try 12 or more characters."),
        Strength.Fair => Loc.T("Fair. A longer one is safer."),
        Strength.Good => Loc.T("Good."),
        _ => Loc.T("Strong."),
    };
}
