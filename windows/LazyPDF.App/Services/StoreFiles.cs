using System.Collections;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using System.Text.Unicode;

namespace LazyPDF.App.Services;

// From Lazy Print's Persistence.cs (Lazy Scan's StoreFiles): the settings files of Lazy PDF,
// kept in the app because Core reads and writes no files of its own (Global rule 8).

internal enum StoreReadStatus
{
    /// <summary>No file yet (first run).</summary>
    Missing,
    /// <summary>The file was read but its contents do not decode; it is safe to move aside.</summary>
    Corrupt,
    /// <summary>
    /// The file could not be read (permissions, I/O, not a regular file). Its contents may be
    /// perfectly valid, so it is left where it is.
    /// </summary>
    Inaccessible,
    Loaded,
}

/// <param name="Status">Which of the read outcomes happened.</param>
/// <param name="Value">Set when <paramref name="Status"/> is <see cref="StoreReadStatus.Loaded"/>.</param>
/// <param name="Error">Set when <paramref name="Status"/> is Corrupt or Inaccessible.</param>
internal readonly record struct StoreReadResult<T>(StoreReadStatus Status, T? Value = null, Exception? Error = null)
    where T : class;

/// <summary>
/// Files that could not be read, or did not decode and could not be moved aside; writes to
/// them are refused for the rest of the session so the original is never overwritten.
/// </summary>
internal static class ProtectedFiles
{
    private static readonly object Gate = new();
    private static readonly HashSet<string> Paths =
        new(OperatingSystem.IsWindows() || OperatingSystem.IsMacOS()
                ? StringComparer.OrdinalIgnoreCase
                : StringComparer.Ordinal);

    internal static void Protect(string path)
    {
        lock (Gate) Paths.Add(Path.GetFullPath(path));
    }

    internal static bool IsProtected(string path)
    {
        lock (Gate) return Paths.Contains(Path.GetFullPath(path));
    }
}

/// <summary>
/// JSON storage under %APPDATA%\Lazy PDF\ (the Windows analogue of
/// ~/Library/Application Support/Lazy PDF/), created on demand.
/// </summary>
internal static class StoreFiles
{
    /// <summary>
    /// Settings-file format. Writing is unchanged from the plain camelCase serializer: every
    /// public property under its camelCase name, enums as camelCase strings. Reading is
    /// tolerant field by field (see <see cref="LenientDecoding"/>), matching the Swift
    /// decodeLenient rule: a missing key, null, wrong-typed value, unknown enum value or
    /// corrupt nested object resets only that property to its default; unknown keys are ignored.
    /// </summary>
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new CamelCaseEnumConverterFactory() },
        TypeInfoResolver = new DefaultJsonTypeInfoResolver
        {
            Modifiers = { LenientDecoding.MakePropertiesLenient },
        },
    };

    internal static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                     "Lazy PDF");

    /// <summary>
    /// Distinguishes "no file yet", "file cannot be read" and "file read but does not decode".
    /// There is no separate existence check, so a file removed just before the read is
    /// reported as missing rather than as a read failure.
    /// </summary>
    internal static StoreReadResult<T> Read<T>(string path) where T : class
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(path);
        }
        catch (Exception error)
        {
            return IsNoSuchFile(error)
                ? new(StoreReadStatus.Missing)
                : new(StoreReadStatus.Inaccessible, Error: error);
        }
        try
        {
            return new(StoreReadStatus.Loaded, Decode<T>(data));
        }
        catch (Exception error)
        {
            return new(StoreReadStatus.Corrupt, Error: error);
        }
    }

    /// <summary>
    /// The decoded value, or null when there is none yet or the file could not be loaded; an
    /// undecodable file is moved aside and an unreadable one is protected from writes.
    /// </summary>
    internal static T? Load<T>(string path) where T : class
    {
        var result = Read<T>(path);
        switch (result.Status)
        {
            case StoreReadStatus.Loaded:
                return result.Value;
            case StoreReadStatus.Corrupt:
                KeepUnreadable(path, result.Error!);
                break;
            case StoreReadStatus.Inaccessible:
                LeaveInaccessible(path, result.Error!);
                break;
        }
        return null;
    }

    /// <summary>
    /// Decodes a whole settings file. Like Swift's JSONDecoder it reads UTF-8, UTF-16 and
    /// UTF-32 (see <see cref="DetectEncoding"/>), requires the text to be valid in that
    /// encoding, and rejects a null document, or a null element of a top-level list, instead
    /// of producing a null value.
    /// </summary>
    internal static T Decode<T>(ReadOnlySpan<byte> json) where T : class
    {
        var (encoding, bomLength) = DetectEncoding(json);
        json = json[bomLength..];
        if (encoding is not null)
            json = Encoding.UTF8.GetBytes(encoding.GetString(json));
        if (!Utf8.IsValid(json))
            throw new JsonException("The file is not valid UTF-8.");
        var value = JsonSerializer.Deserialize<T>(json, JsonOptions);
        if (value is null || LenientDecoding.ContainsNull(value))
            throw new JsonException($"The file does not contain a {typeof(T).Name}.");
        return value;
    }

    /// <summary>
    /// The encoding of a settings file, the same way Swift's JSONDecoder determines it: a
    /// leading UTF-8, UTF-32 or UTF-16 byte-order mark wins; without one, the pattern of zero
    /// bytes around the first (always ASCII) JSON character identifies UTF-32 or UTF-16, and
    /// anything else is UTF-8. Returns null for UTF-8 and the length of the byte-order mark.
    /// The decoders throw on invalid input, so a damaged file still counts as corrupt.
    /// </summary>
    internal static (Encoding? Encoding, int BomLength) DetectEncoding(ReadOnlySpan<byte> data)
    {
        if (data.StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF])) return (null, 3);
        if (data.StartsWith((ReadOnlySpan<byte>)[0x00, 0x00, 0xFE, 0xFF])) return (Utf32(bigEndian: true), 4);
        if (data.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xFE, 0x00, 0x00])) return (Utf32(bigEndian: false), 4);
        if (data.StartsWith((ReadOnlySpan<byte>)[0xFE, 0xFF])) return (Utf16(bigEndian: true), 2);
        if (data.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xFE])) return (Utf16(bigEndian: false), 2);
        if (data.Length >= 4)
        {
            return (data[0], data[1], data[2], data[3]) switch
            {
                (0, 0, 0, _) => (Utf32(bigEndian: true), 0),
                (_, 0, 0, 0) => (Utf32(bigEndian: false), 0),
                (0, _, 0, _) => (Utf16(bigEndian: true), 0),
                (_, 0, _, 0) => (Utf16(bigEndian: false), 0),
                _ => (null, 0),
            };
        }
        if (data.Length >= 2)
        {
            if (data[0] == 0) return (Utf16(bigEndian: true), 0);
            if (data[1] == 0) return (Utf16(bigEndian: false), 0);
        }
        return (null, 0);

        static Encoding Utf32(bool bigEndian) =>
            new UTF32Encoding(bigEndian, byteOrderMark: false, throwOnInvalidCharacters: true);
        static Encoding Utf16(bool bigEndian) =>
            new UnicodeEncoding(bigEndian, byteOrderMark: false, throwOnInvalidBytes: true);
    }

    /// <summary>True when <paramref name="error"/> means the file (or its folder) does not exist.</summary>
    internal static bool IsNoSuchFile(Exception error) =>
        error is FileNotFoundException or DirectoryNotFoundException;

    /// <summary>
    /// Leaves a file that could not be read where it is and refuses further writes to it
    /// for the rest of the session, so a transient failure never replaces valid contents.
    /// </summary>
    internal static void LeaveInaccessible(string path, Exception error)
    {
        ProtectedFiles.Protect(path);
        Trace.TraceError($"Could not read {Path.GetFileName(path)} ({error.Message}); "
                         + "left it in place and will not overwrite it this session");
    }

    /// <summary>
    /// Moves a file that does not decode aside to &lt;name&gt;.unreadable-&lt;yyyyMMdd-HHmmss&gt;.json
    /// in the same folder (adding -2, -3, ... when that name is taken). When it cannot be
    /// moved, further writes to <paramref name="path"/> are refused instead, unless the move
    /// failed because the file is already gone.
    /// </summary>
    internal static void KeepUnreadable(string path, Exception error)
    {
        string stem = Path.GetFileNameWithoutExtension(path) + ".unreadable-"
                      + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        string folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
        string target = Path.Combine(folder, stem + ".json");
        for (int suffix = 2; Path.Exists(target); suffix++)
        {
            target = Path.Combine(folder, $"{stem}-{suffix}.json");
        }
        string problem = $"Could not decode {Path.GetFileName(path)} ({error.Message})";
        try
        {
            File.Move(path, target);
            Trace.TraceError($"{problem}; kept it as {Path.GetFileName(target)}");
        }
        catch (Exception moveError) when (IsNoSuchFile(moveError))
        {
            Trace.TraceError($"{problem}; it was removed before it could be kept ({moveError.Message})");
        }
        catch (Exception moveError)
        {
            ProtectedFiles.Protect(path);
            Trace.TraceError($"{problem} and could not move it aside ({moveError.Message}); "
                             + "it will not be overwritten");
        }
    }

    /// <summary>
    /// Best-effort atomic write; creates the directory on demand. Refuses to replace a file
    /// that could not be read, or that did not decode and could not be moved aside. Returns
    /// whether the file was written.
    /// </summary>
    internal static bool Write<T>(T value, string path)
    {
        if (ProtectedFiles.IsProtected(path)) return false;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(value, JsonOptions));
            File.Move(tmp, path, overwrite: true);
            return true;
        }
        catch
        {
            // Best effort, mirroring the Swift store's try?.
            return false;
        }
    }
}

/// <summary>
/// Field-by-field tolerant reading for every object type in a settings file, the C# form of
/// Swift's KeyedDecodingContainer.decodeLenient(forKey:default:). Each property's value is
/// decoded on its own; when it is null or does not decode (wrong type, an enum value this
/// version does not know, a corrupt nested object) the property gets the value a freshly
/// constructed instance has, so one bad field never fails the enclosing object or file.
/// Missing keys keep the constructor's default and unknown keys are ignored, as before.
/// New persisted properties therefore only need an initializer default; persisted types need
/// a public parameterless constructor (types without one are decoded strictly).
/// </summary>
internal static class LenientDecoding
{
    internal static void MakePropertiesLenient(JsonTypeInfo typeInfo)
    {
        if (typeInfo.Kind != JsonTypeInfoKind.Object || typeInfo.CreateObject is not { } create) return;
        foreach (var property in typeInfo.Properties)
        {
            if (property.Set is null || property.Get is not { } get) continue;
            Func<object?> fallback = () => get(create());
            // A converter attached to the property itself keeps doing the actual reading and writing.
            var inner = property.CustomConverter is JsonConverterFactory factory
                ? factory.CreateConverter(property.PropertyType, typeInfo.Options)
                : property.CustomConverter;
            property.CustomConverter = (JsonConverter)Activator.CreateInstance(
                typeof(LenientPropertyConverter<>).MakeGenericType(property.PropertyType),
                fallback, inner)!;
        }
    }

    /// <summary>
    /// True when <paramref name="value"/> is a collection holding a null element. Persisted
    /// collections never hold nulls, and Swift fails to decode one, so such a value is
    /// treated as undecodable.
    /// </summary>
    internal static bool ContainsNull(object value)
    {
        if (value is string || value is not IEnumerable items) return false;
        foreach (var item in items)
        {
            if (item is null) return true;
        }
        return false;
    }
}

/// <summary>Reads one property leniently (see <see cref="LenientDecoding"/>); writes it unchanged.</summary>
internal sealed class LenientPropertyConverter<T> : JsonConverter<T>
{
    private readonly Func<object?> _fallback;
    private readonly JsonConverter<T>? _inner;

    public LenientPropertyConverter(Func<object?> fallback, JsonConverter? inner)
    {
        _fallback = fallback;
        _inner = inner is null ? null
            : inner as JsonConverter<T>
              ?? throw new InvalidOperationException($"{inner.GetType().Name} cannot convert {typeof(T).Name}.");
    }

    /// <summary>Nulls reach <see cref="Read"/> so they fall back to the default too.</summary>
    public override bool HandleNull => true;

    public override T? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null) return Fallback();
        // Malformed JSON throws here and fails the whole file, as in Swift, where the
        // document is parsed before any value is decoded.
        using var document = JsonDocument.ParseValue(ref reader);
        try
        {
            var value = DecodeValue(document.RootElement, options);
            if (value is null || LenientDecoding.ContainsNull(value)) return Fallback();
            return value;
        }
        catch (Exception)
        {
            return Fallback();
        }
    }

    private T? DecodeValue(JsonElement element, JsonSerializerOptions options)
    {
        if (_inner is null) return element.Deserialize<T>(options);
        var reader = new Utf8JsonReader(Encoding.UTF8.GetBytes(element.GetRawText()));
        reader.Read();
        return _inner.Read(ref reader, typeof(T), options);
    }

    private T? Fallback() => (T?)_fallback();

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
    {
        if (_inner is not null)
            _inner.Write(writer, value, options);
        else
            JsonSerializer.Serialize(writer, value, options);
    }
}

/// <summary>
/// Enums as camelCase strings, the Swift rawValues ("light", "dark"). Reading
/// is exact like Swift's: only a string naming a member, compared case-sensitively; numbers,
/// other casings and unknown names (written by a newer version) do not decode, and the
/// property falls back to its default. The first member of every persisted enum is that
/// default and the safe fallback. Writing matches the previous JsonStringEnumConverter.
/// </summary>
internal sealed class CamelCaseEnumConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) => typeToConvert.IsEnum;

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options) =>
        (JsonConverter)Activator.CreateInstance(typeof(CamelCaseEnumConverter<>).MakeGenericType(typeToConvert))!;
}

internal sealed class CamelCaseEnumConverter<T> : JsonConverter<T> where T : struct, Enum
{
    private static readonly Dictionary<string, T> ByName = [];
    private static readonly Dictionary<T, string> ByValue = [];

    static CamelCaseEnumConverter()
    {
        foreach (string name in Enum.GetNames<T>())
        {
            var value = Enum.Parse<T>(name);
            string camelCase = JsonNamingPolicy.CamelCase.ConvertName(name);
            ByName.TryAdd(camelCase, value);
            ByValue.TryAdd(value, camelCase);
        }
    }

    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String
            && reader.GetString() is { } name
            && ByName.TryGetValue(name, out var value))
        {
            return value;
        }
        throw new JsonException($"Not a known {typeof(T).Name} value.");
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
    {
        if (ByValue.TryGetValue(value, out var name))
            writer.WriteStringValue(name);
        else
            writer.WriteNumberValue(Convert.ToDecimal(value, CultureInfo.InvariantCulture));
    }
}
