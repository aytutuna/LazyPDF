# Lazy PDF website

The product page for Lazy PDF: static `index.html` and `privacy.html`, one `style.css` and the screenshots in `assets/`.
The screenshots are light and dark pairs of the app's own windows with test files; the index page picks one by the visitor's colour scheme.
To preview it, open `index.html` in a browser, or run `python -m http.server 8000` from this folder.
There is no build step. The pages are served at alazy.app/pdf/ from the shared alazy repo; this folder is the source until it moves, and the store links use https://alazy.app/pdf/ and https://alazy.app/pdf/privacy.html. `privacy.html` and the Support section are the privacy and support URLs for the Microsoft Store and the Mac App Store listings.
Until the listings exist, the home page says the app is not released; the place for the store links is marked with a comment in the hero section of `index.html`.
`privacy.html` was written from the code: if a service in `windows/LazyPDF.App/Services` starts making a request or writing a new file, change it in the same commit.
