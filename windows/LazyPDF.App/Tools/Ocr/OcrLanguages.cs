using System.Globalization;
using Windows.Globalization;
using Windows.Media.Ocr;
using Windows.System.UserProfile;

namespace LazyPDF.App.Tools.Ocr;

/// <param name="Tag">A BCP 47 tag, as the recognizer takes it.</param>
public sealed record OcrLanguage(string Tag, string Name);

/// <summary>The OCR languages Windows has, and the ones its user asked for that it lacks.</summary>
public sealed record OcrLanguageState(IReadOnlyList<OcrLanguage> Installed, IReadOnlyList<string> Missing)
{
    public static OcrLanguageState Read()
    {
        var installed = OcrEngine.AvailableRecognizerLanguages
            .Select(l => new OcrLanguage(l.LanguageTag, l.DisplayName))
            .OrderBy(l => l.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
        var missing = GlobalizationPreferences.Languages
            .Select(tag => new Language(tag))
            .Where(l => !OcrEngine.IsLanguageSupported(l))
            .Select(l => l.DisplayName)
            .Distinct()
            .ToList();
        return new OcrLanguageState(installed, missing);
    }

    /// <summary>The one the list starts on: the language of the app, else English, else the first.</summary>
    public OcrLanguage? Preferred()
    {
        string own = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        return Installed.FirstOrDefault(l => Same(l, own)) ?? Installed.FirstOrDefault(l => Same(l, "en")) ?? Installed.FirstOrDefault();
    }

    /// <summary>What is missing and where to add it. A language Windows has no OCR for cannot be added, hence the "if".</summary>
    public string Advice
    {
        get
        {
            string names = string.Join(", ", Missing);
            if (Installed.Count == 0)
            {
                return Missing.Count == 0
                    ? Loc.T("No OCR language is installed. In Settings, Language and region, add a language, then add Optical character recognition in its options.")
                    : Loc.T("No OCR language is installed. For {0}, open its options in Settings, Language and region and add Optical character recognition if it is listed.", names);
            }
            return Missing.Count == 0
                ? Loc.T("Need another language? In Settings, Language and region, add it and its Optical character recognition.")
                : Loc.T("No OCR for {0}. Open its options in Settings, Language and region and add Optical character recognition if it is listed.", names);
        }
    }

    private static bool Same(OcrLanguage language, string twoLetter) =>
        language.Tag.StartsWith(twoLetter, StringComparison.OrdinalIgnoreCase);
}
