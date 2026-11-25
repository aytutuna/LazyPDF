App Store Connect notes for Lazy PDF (paste from here)

One record (Apple ID 6833007638, bundle id com.lazypdf.lazypdf, SKU lazypdf) for iPhone, iPad and Mac. Primary language English (U.S.). The text below is shared by all three unless a section says otherwise.

Name: Lazy PDF

Subtitle (30): Read, fill, sign and edit
  = 25 chars

Promotional text (170):
Read PDFs, fill forms, sign, redact, merge, split and make files smaller. Free, no account, and your files stay on your device unless you share them.
  = 149 chars

Description:
Lazy PDF opens PDF files and lets you change them. It is free, and it has no account, no ads and no analytics.

Open a file and choose a tool from the strip. You can highlight and leave notes, measure distances and areas, fill in forms, sign with a drawn signature or a certificate, rearrange pages, join and split files, change the words and pictures already on a page, add stamps, watermarks and page numbers, set a password, remove text and pictures for good, take hidden data out before a file goes to someone else, make a file smaller, save it as Word, Excel, PowerPoint, HTML, text or pictures, make scanned pages searchable, compare two files, and check a file for screen readers and PDF/A.

Read with search, bookmarks, page thumbnails, layers and attachments. See in plain words who signed a file and whether it changed since. To sign with a certificate, bring a .p12 or .pfx file; it is kept in the keychain on your device.

Every change is a step you can undo. While you work, an unsaved copy is kept on your device, and the app offers it back if it closes by accident. On iPhone and iPad a file is opened where it is, in Files or iCloud Drive, and saved back to the same place.

Make a PDF from blank pages, pictures, text or the clipboard. Do the same job to every file in a folder with Batch.

Text on scanned pages is recognized on the device with the text recognition built into iOS and macOS. Nothing is uploaded.

The only time the app uses the network is when you sign with a certificate and ask for a time stamp or for validation data. It then talks to the time stamp server whose address you typed in, and to the places the certificate itself names. Everything else happens on your device.

On Mac, Print hands the file to Lazy Print when it is installed. When Lazy Scan is installed, a Scan tile starts it. Lazy PDF, Lazy Scan and Lazy Print are sister apps. Lazy PDF is free, and its source is available under PolyForm Noncommercial 1.0.0.

Lazy PDF is new. If a file does not open or change as it should, write to support@alazy.app.

Keywords (100, comma separated, no spaces):
sign,merge,split,redact,compress,form,annotate,ocr,editor,reader,convert,password,watermark,pages
  = 97 chars

What's new in version 1.0:
First release.

Primary category: Productivity
Secondary category: Utilities
Support URL: https://alazy.app/pdf/
Marketing URL: https://alazy.app/pdf/
Privacy policy URL: https://alazy.app/pdf/privacy.html
Copyright: 2026 Aytu Tuna
Price: free (no in-app purchases), all regions
Sign-in required: off (the notes do not save while it is on)

Age rating: 4+ (answer No to everything)
Violence, sexual content, profanity, horror, drugs, gambling, contests: None. The app shows the user's own files and has no content of its own.
Unrestricted web access: No. The app has no browser. A link in a file shows its address and asks; only http, https and mailto are opened, by the system.
User-generated content, messaging, ads, in-app purchases: No. No account, chat, feed or sharing feature in the code.
Medical or health information: No.

App Privacy: Data Not Collected
Nothing is sent to the developer or to a server run for the app, and the code has no analytics, crash reporting, advertising or update check. PrivacyInfo.xcprivacy (ios/LazyPDFiOS and mac/LazyPDFMacApp) lists no collected data types and no tracking. The only network code is the time stamp and validation data requests, made on the user's own action, with URLSession for https (Sources/LazyPDFApp/Apple/UrlSessionTransport.swift) and Network.framework for plain http (PlainHttpTransport.swift). They go to servers the user or the certificate names, and no file, text or identifier is sent: a time stamp request holds a hash of the signature, a validation request holds hashes of the issuer and the certificate's serial number. Recent files, settings, recovery copies and thumbnails stay in the app's own container. Required-reason APIs declared: UserDefaults (CA92.1), file timestamps (C617.1, 3B52.1), system boot time (35F9.1).

Export compliance: Info.plist sets ITSAppUsesNonExemptEncryption to false on both platforms, so App Store Connect does not ask per build. If the questionnaire ever comes up: uses encryption yes, only standard algorithms (AES and RC4 for PDF passwords, RSA and SHA-2 for signatures, TLS), so exempt, nothing to upload.

Content rights: the app contains no third-party content. It shows only files the user opens.

App Review notes (iOS and macOS):
Nothing to sign in to; there are no accounts. No special file is needed: use any PDF, for example one from Files or a page saved as PDF. The Open tile on the Home tab opens it, and a picture or a text file opens too.
To try the tools, open a file and choose a tool from the strip: Comment to highlight and add a note, Fill and sign to draw a signature, Organize pages to rotate or delete a page, Combine files to join two PDFs, Protect to set a password, Redact to remove text for good, Make smaller to shrink the file, Export to save as text or pictures, Make searchable on a scanned page, Compare files with two PDFs. Create makes a PDF from blank pages, pictures or text without any file.
Certificates (in the Sign group) needs a .p12 or .pfx file with a private key. A reviewer can make one with openssl (openssl pkcs12 -export -inkey key.pem -in cert.pem -out test.p12) or skip it; every other tool works without. The time stamp switch is off by default and needs the address of a time stamp server; with it off, nothing is sent over the network.
Lazy Scan and Lazy Print are separate apps. Without them the Scan tile is hidden and Print uses the system print sheet. Nothing else needs them.

iPhone and iPad specifics:
A file is opened in place from Files (LSSupportsOpeningDocumentsInPlace) and saved back there; the app keeps a bookmark of each recent file. Print always uses the system print sheet: Lazy Print is not called from iOS, because a file cannot be handed to another app by path. A certificate imported from a .p12 is stored in the app's keychain group. Info.plist lists lazyscan and lazyprint in LSApplicationQueriesSchemes so the app can ask whether Lazy Scan is installed; it opens Lazy Scan with a lazyscan: address and passes no file. An attachment inside a PDF opens in the system preview.
Entitlements: keychain-access-groups with the app's own group, for imported identities.

Mac App Store notes:
The Mac build is a sandboxed target on the same record. Entitlements: app-sandbox; files.user-selected.read-write for files and folders the user picks, Batch folders and saved exports; files.bookmarks.app-scope so recent files and a Batch folder open again after a relaunch; network.client for the time stamp and validation data requests, and only those; print for the print sheet. There is no network.server, so the app listens for nothing.
Print hands the file to Lazy Print through NSWorkspace when it is installed (the sandbox grant goes with the file), and falls back to the system print dialog when it is not or when it fails to open. The Scan tile starts Lazy Scan by bundle id through NSWorkspace and passes no file.
A .p12 the user picks is read in the app and imported into the keychain, and the signing choices come from the keychain identities.
An attachment inside a PDF is written to the app's temporary folder and opened with NSWorkspace.
Screenshots: 2560x1600, without alpha.
