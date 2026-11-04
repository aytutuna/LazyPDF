namespace LazyPDF.Core;

/// <summary>Image XObjects made from pixels or a JPEG file, ready to paint with <see cref="ContentWriter.Paint(string, PdfMatrix)"/>.</summary>
public static class ContentImages
{
    /// <summary>
    /// An RGB image, Flate-compressed, with an /SMask when any pixel is not opaque.
    /// <paramref name="rgba"/> is straight RGBA8, top row first, as <see cref="PdfRgbaImage"/> has it.
    /// </summary>
    public static PdfReference AddRgba(PdfDocument document, int width, int height, byte[] rgba)
    {
        if (width < 1 || height < 1 || (long)width * height > PdfImageSamples.MaxPixels || rgba.Length != (long)width * height * 4)
            throw new ArgumentException("The pixel data does not fit the size.");
        var rgb = new byte[width * height * 3];
        var alpha = new byte[width * height];
        bool translucent = false;
        for (int i = 0, o = 0; i < alpha.Length; i++)
        {
            rgb[o++] = rgba[4 * i];
            rgb[o++] = rgba[4 * i + 1];
            rgb[o++] = rgba[4 * i + 2];
            alpha[i] = rgba[4 * i + 3];
            translucent |= alpha[i] != 255;
        }
        var image = Image(width, height, "DeviceRGB", 8);
        if (translucent)
        {
            var mask = Image(width, height, "DeviceGray", 8);
            mask.Data = PdfFilterEncoders.Flate(alpha);
            image.Dictionary["SMask"] = document.Add(mask);
        }
        image.Data = PdfFilterEncoders.Flate(rgb);
        return document.Add(image);
    }

    /// <summary>A JPEG file embedded as it is (DCTDecode); null when its header cannot be read.</summary>
    public static PdfReference? AddJpeg(PdfDocument document, byte[] jpeg)
    {
        if (!ReadJpegHeader(jpeg, out int width, out int height, out int components, out bool adobe)) return null;
        string space = components switch { 1 => "DeviceGray", 3 => "DeviceRGB", _ => "DeviceCMYK" };
        var image = Image(width, height, space, 8);
        image.Dictionary["Filter"] = new PdfName("DCTDecode");
        // Adobe writes CMYK JPEGs inverted.
        if (components == 4 && adobe) image.Dictionary["Decode"] = new PdfArray([.. Enumerable.Range(0, 8).Select(i => (PdfObject)new PdfNumber(i % 2 == 0 ? 1L : 0L))]);
        image.Data = jpeg;
        return document.Add(image);
    }

    private static PdfStream Image(int width, int height, string space, int bits)
    {
        var dictionary = new PdfDictionary();
        dictionary["Type"] = new PdfName("XObject");
        dictionary["Subtype"] = new PdfName("Image");
        dictionary["Width"] = new PdfNumber(width);
        dictionary["Height"] = new PdfNumber(height);
        dictionary["ColorSpace"] = new PdfName(space);
        dictionary["BitsPerComponent"] = new PdfNumber(bits);
        dictionary["Filter"] = new PdfName("FlateDecode");
        return new PdfStream(dictionary, []);
    }

    private static bool ReadJpegHeader(byte[] d, out int width, out int height, out int components, out bool adobe)
    {
        (width, height, components, adobe) = (0, 0, 0, false);
        if (d.Length < 4 || d[0] != 0xFF || d[1] != 0xD8) return false;
        int p = 2;
        while (p + 4 <= d.Length)
        {
            if (d[p] != 0xFF)
            {
                p++;
                continue;
            }
            int marker = d[p + 1];
            if (marker is 0xFF or 0x00 or (>= 0xD0 and <= 0xD8) or 0x01)
            {
                p += marker == 0xFF ? 1 : 2;
                continue;
            }
            int length = d[p + 2] << 8 | d[p + 3];
            if (marker == 0xEE && length >= 7 && p + 9 <= d.Length && d[p + 4] == 'A' && d[p + 5] == 'd') adobe = true;
            if (marker is >= 0xC0 and <= 0xCF and not (0xC4 or 0xC8 or 0xCC))
            {
                if (p + 10 > d.Length) return false;
                height = d[p + 5] << 8 | d[p + 6];
                width = d[p + 7] << 8 | d[p + 8];
                components = d[p + 9];
                return width > 0 && height > 0 && components is 1 or 3 or 4;
            }
            p += 2 + length;
        }
        return false;
    }
}
