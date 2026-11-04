# Lazy PDF — module contracts

Native PDF editor for Windows, macOS and the iPhone, the third of the Lazy apps with Lazy Scan (`../LazyScan`) and Lazy Print (`../LazyPrint`), whose layout and conventions it shares. The Windows app is .NET 10 and WPF. The Swift targets (`LazyPDFKit`, `LazyPDFMac`, `LazyPDFIOS`) follow once the C# engine has settled, the order Lazy Print was built in.

**System frameworks only.** Core has no third-party code. It may use `System.Security.Cryptography.Pkcs`, Microsoft's own CMS package, for signatures; that is the one package reference it has. PdfPig stays in the test project, as in Lazy Scan.

## The split: our engine, the system's pixels

Lazy PDF owns the file format and leaves drawing a page to the system. Everything that reads, understands or changes a PDF is in `LazyPDF.Core` and written by us. Turning a page into pixels is `Windows.Data.Pdf` on Windows and PDFKit on Apple, behind `IPageRenderer`. This is what keeps the app small: a renderer with full font, colour and transparency support is years of work and the systems already have one, while none of them will edit a file.

## Global rules

1. Core uses no UI and no OS-specific API. It takes bytes and gives bytes. Fonts, images it cannot decode, OCR and time reach it through small interfaces an app passes in.
2. A helper not listed here is `private` or `internal`.
3. Coordinates: the engine speaks PDF user space (points, origin bottom-left) in page objects and content. App geometry is points with origin top-left and y down, as in the sisters. `PageGeometry` converts between them and applies `/Rotate` and the crop box; nothing else does.
4. Reading is forgiving, writing is strict. The reader repairs what it can and says so (`PdfDocument.Repairs`); what the writer emits must pass a strict parser. No third-party file ever crashes the engine: bad input throws `PdfReadException`, and every recursion and allocation driven by file contents has a cap.
5. Never lose the user's data. A save goes to a temporary file, is read back, then replaces the original. Signed files get incremental updates only, unless the user chooses otherwise.
6. Files as written by us reopen in `Windows.Data.Pdf` and PdfPig. Every writer test does this.
7. User text is short, as in the sisters: a status line is six words at most with the full sentence for screen readers, a problem is titled by what is wrong and says what to do. It goes through `Loc.T` (English is the key) and Turkish lands with it. Texts both platforms show live in Core, in a `...Text` type.
8. Settings files load across versions by Lazy Scan's rules (Global rule 6 there), in `%APPDATA%\Lazy PDF`.
9. Code copied from a sister says so in its header: "From Lazy Scan's PdfSyntax.cs". Copying with the names changed is how code moves between the three repos.

## Names

"Lazy PDF" in text, `LazyPDF` in code. Scheme `lazypdf:`, mutex `Local\LazyPDF.App`, pipe `LazyPDF.Open.<session id>`, settings folder `Lazy PDF`, phone link `_lazypdf._tcp` on port 52733 with mutex `Local\LazyPDF.PhoneLink`. On Apple a Viewer of `com.adobe.pdf` at Alternate rank, so it never takes over a default.

## Layers

`LazyPDF.Core`, one folder per layer, each using only the layers before it.

| Folder | Holds | Uses |
|---|---|---|
| `Syntax/` | values, lexer | |
| `Filters/` | stream filters, predictors, image sample decoding | Syntax |
| `Crypt/` | standard security handler, RC4 and AES, reading and writing | Syntax |
| `Fonts/` | encodings, CMaps, Standard 14 metrics, TrueType, CFF and Type 1 parsing, subsetting | Syntax, Filters |
| `Document/` | reader with repair, object table, page tree, saving (incremental and rewrite), edit sessions | Syntax, Filters, Crypt |
| `Content/` | content stream parsing and writing, the graphics state interpreter | Document, Fonts |
| `Text/` | characters with positions, words, lines, selection, search | Content |
| `Pages/` | rotate, delete, insert, reorder, extract, merge, split, crop, resize | Document |
| `Structure/` | outlines, destinations, page labels, attachments, metadata, layers, links | Document |
| `Annotations/` | reading, creating, appearance streams | Content, Fonts |
| `Forms/` | AcroForm fields, filling, authoring, flattening, FDF | Annotations |
| `Stamps/` | watermarks, headers and footers, Bates numbers, backgrounds | Content, Fonts |
| `Redaction/` | removing text, images and paths for real | Text |
| `Signatures/` | signing, verifying, timestamps, change detection | Document |
| `Optimize/` | smaller files, sanitizing | Document, Content |
| `Standards/` | PDF/A conversion and checks | Document, Content |
| `Editing/` | changing text and images already on a page | Text, Fonts |
| `Compare/` | text and picture differences between two files | Text |
| `Export/` | text, Word, HTML, images from pages, PDFs from images | Text |

## The edit session

An open file is one growing byte buffer. Each edit commits an incremental update (ISO 32000-1 7.5.6) to the end of it, and undo moves the end back to the previous `%%EOF`; redo moves it forward. So undo is exact and cheap, the renderer always reads a complete valid PDF, and a crash loses nothing that was autosaved. `Save` writes the buffer as it stands; `Save compact` rewrites it without the history.

## Feature target

Against Acrobat Pro. Skipped on purpose: XFA dynamic forms (detected and reported), 3D and rich media, Adobe DRM, cloud review and cloud signing requests, press separations and trapping.

Beyond Acrobat: scan into the open file through Lazy Scan, print with Lazy Print's booklets and N-up, one-click clean for sharing, redaction by pattern with a report of what was removed, signature checks in plain words, every saved version recoverable from the file, phone capture and signing over the phone link, folder rules, and all of it offline with no account.

# Modules

Each section below is written when its layer lands.
