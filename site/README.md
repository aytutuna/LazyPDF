# Lazy PDF website

The product page for Lazy PDF: static `index.html` and `privacy.html`, one `style.css` and the screenshots in `assets/`.
The screenshots are light and dark pairs of the app's own windows with test files; the index page picks one by the visitor's colour scheme.
To preview it, open `index.html` in a browser, or run `python -m http.server 8000` from this folder.
There is no build step. `.github/workflows/pages.yml` deploys the folder to GitHub Pages on every push to `main` that touches `site/` (and by hand from the Actions tab). Pages must be set to the GitHub Actions source under Settings > Pages, with `pdf.alazy.app` as the custom domain, the address built into the app and the listing (a CNAME record on `pdf` pointing at aytutuna.github.io). `privacy.html` and the Support section are the privacy and support URLs for the Microsoft Store and the Mac App Store listings.
Until the listings exist, the home page says the app is not released; the place for the store links is marked with a comment in the hero section of `index.html`.
`privacy.html` was written from the code: if a service in `windows/LazyPDF.App/Services` starts making a request or writing a new file, change it in the same commit.
