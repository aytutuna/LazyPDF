#!/bin/bash
# Builds Lazy PDF in release mode and packages dist/Lazy PDF.app
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building (release)..."
swift build -c release

APP="dist/Lazy PDF.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/LazyPDF "$APP/Contents/MacOS/LazyPDF"
cp -R l10n/out/apple/tr.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>tr</string></array>
    <key>CFBundleName</key>              <string>Lazy PDF</string>
    <key>CFBundleDisplayName</key>       <string>Lazy PDF</string>
    <key>CFBundleIdentifier</key>        <string>local.lazypdf.app</string>
    <key>CFBundleExecutable</key>        <string>LazyPDF</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSApplicationSupportsSecureRestorableState</key> <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>PDF document</string>
            <key>CFBundleTypeRole</key>      <string>Editor</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>    <array><string>com.adobe.pdf</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>      <string>Picture</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.jpeg</string>
                <string>public.png</string>
                <string>public.tiff</string>
                <string>com.microsoft.bmp</string>
                <string>com.compuserve.gif</string>
                <string>public.heic</string>
                <string>public.heif</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>      <string>Plain text</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>    <array><string>public.plain-text</string></array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>Lazy PDF</string>
            <key>CFBundleURLSchemes</key>    <array><string>lazypdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The Mac icon set uses the iconset file names, so it converts as it is.
ICONSET=dist/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp mac/LazyPDFMacApp/Assets.xcassets/AppIcon.appiconset/*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Signing (ad-hoc)..."
codesign --force --deep -s - "$APP"

echo "==> Done: $APP"
echo "    Launch with:  open \"$APP\""
