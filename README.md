# Lazy PDF

A PDF app for Windows: read, fill, sign, edit, redact, rearrange, compare and convert PDF files, offline and without an account. It is the third of the Lazy apps, after Lazy Scan and Lazy Print, and shares their layout and conventions. It is free, and the source is public to read.

The window has a Home tab with the jobs people come for and the files opened last, and a tab for each open document. A document has a tool strip (comment, measure, edit text and pictures, stamps, pages, forms, fill and sign, certificates, protect, redact, clean for sharing, make smaller, export, batch, make searchable, compare, accessibility, PDF/A), a rail of side panels (pages, bookmarks, attachments, layers, comments, signatures, search) and the page. Changes are steps that can be undone one at a time, and an unsaved copy is kept so a crash does not lose them.

The engine is written here and reads, repairs, changes and writes PDF files itself. Turning a page into pixels, recognizing text and reading images is left to Windows. Print hands the open file to Lazy Print when it is installed, and the Scan tile starts Lazy Scan.

## Status

The app has only been tested by its automated suites and by drawing its windows off screen. Nobody has used it with a real mouse on their own files yet. Signed files have been checked with pyHanko only, not Acrobat.

## Layout

```
CONTRACTS.md          the spec: what each module does, the names, what the tests check
windows/              C# solution
  LazyPDF.Core        the engine, no UI and no OS calls
  LazyPDF.App         the WPF app
  *.Tests             one test project for each
store/windows/        Microsoft Store package: manifest, tiles, listing text and screenshots
scripts/              icon and tile drawing, string tables, package script
l10n/                 shared.json (English and Turkish texts) and the Turkish glossary
site/                 the web pages
Tests/Fixtures        files the tests read
THIRD-PARTY-NOTICES.txt   shipped with the app and shown in About
```

## Build and test

Windows needs the .NET 10 SDK:

```
dotnet build windows/LazyPDF.sln -c Release
dotnet test windows/LazyPDF.sln
dotnet run --project windows/LazyPDF.App
```

Texts are English in the code and Turkish in `l10n/shared.json`. After changing either, run `python scripts/gen_l10n.py`, which writes `windows/LazyPDF.Core/Strings.tr.resx` and fails on a text without a translation or one nothing uses.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and `ci/**` branches and on pull requests to `main`. It checks that the Turkish resource file is up to date, builds the solution and runs the tests.

## Release

The app is published on the Microsoft Store, which signs the package and delivers updates. `release.yml` runs by hand from the Actions tab. It publishes the app self-contained for x64 and arm64, so nobody has to install .NET, packs each with `makeappx` from the runner's Windows SDK through `scripts/make_msix.ps1`, bundles the two and uploads `LazyPDF_<version>.msixupload` as the `lazypdf-store` artifact. The package is not signed; the Store does that.

The version is `Version` in `windows/Directory.Build.props`. The package version is that with a `.0` added, and the Store wants it higher for every submission.

`store/windows/Package.appxmanifest` holds the package identity as three names taken from Partner Center, which the workflow replaces from repository variables: `STORE_IDENTITY_NAME`, `STORE_PUBLISHER` (the `CN=...` string) and `STORE_PUBLISHER_DISPLAY_NAME`. The workflow stops at its first step when one is missing. The tiles and logos in `store/windows/Assets` are drawn by `scripts/make_store_assets.py` from the same drawing as the icon (`scripts/make_ico.py`).

To check a package on a PC without the Store: publish with `dotnet publish windows/LazyPDF.App -c Release -r win-x64 --self-contained -o <folder>`, run `scripts/make_msix.ps1 -X64 <folder> -Out <folder>` and sign the `.msix` with a test certificate whose subject matches the identity. The script with no identity values keeps the placeholder names, which is enough to see that the package builds.

Only the owner can do these, and `store/windows/listing.md` has them in order: create the app in Partner Center and reserve the name, copy the three identity values into the repository variables, fill in the listing and the age rating, upload the `.msixupload`, and submit.

The site's pages are in `site/`. Until the app is on the Store it says so.

## Licence

PolyForm Noncommercial 1.0.0: free for personal, study and research use, and commercial use needs written permission. The source is available, but this is not an open source licence. See `LICENSE`. Third-party components keep their own licences, listed in `THIRD-PARTY-NOTICES.txt`.
